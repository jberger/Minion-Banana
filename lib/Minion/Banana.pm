package Minion::Banana;

use Mojo::Base -base;
use Mojo::Pg;
use Mojo::Pg::Migrations;
use Mojo::JSON 'j';
use Mojo::IOLoop;

use Safe::Isa '$_isa';

# see Importer.pm
our @EXPORT_OK = (qw[parallel sequence]);

has migrations => sub {
  Mojo::Pg::Migrations->new(pg => shift->pg, name => 'minion_banana')->from_data;
};
has minion => sub { die 'a minion attribute is required' };
has pg => sub {
  my $backend = shift->minion->backend;
  die 'a pg attribute is required'
    unless $backend->$_isa('Minion::Backend::Pg');
  return $backend->pg;
};

sub app { shift->minion->app }

sub attach {
  my ($self, $minion) = @_;
  $self->minion($minion) if $minion;
  $self->migrations->migrate;
  $self->minion->on(worker => \&_worker);
  $self->app->helper(minion_banana => sub { $self });
  return $self;
}

sub manage {
  my $self = shift;
  my $jobs = $self->jobs_ready;
  $self->enable_jobs($jobs);
  $self->pg->pubsub->listen(minion_banana => sub {
    my ($pubsub, $payload) = @_;
    my $data = j $payload;
    if ($data->{success}) {
      Mojo::IOLoop->delay(
        sub { $self->_update($data->{job}, 1, shift->begin) },
        sub {
          my ($delay, $err, $results) = @_;
          die $err if $err;
          return unless $results->rows;
          $self->jobs_ready($results->hash->{group}, shift->begin);
        },
        sub {
          my ($delay, $err, $jobs) = @_;
          die $err if $err;
          $self->enable_jobs($jobs, $delay->begin);
        },
        sub { say 'done' },
      )->catch(sub { warn "update failed: $_[1]" });
    } else {
      $self->_update($data->{job}, 0, sub {})
    }
  });
  Mojo::IOLoop->start;
}

sub _update {
  my ($self, $job, $success, $cb) = @_;
  my $query = <<'  SQL';
    UPDATE minion_banana_jobs
    SET status=?
    WHERE id=? AND status='enabled'
    RETURNING id, group_id, status
  SQL
  my @args = ($success ? 'finished' : 'failed', $job);
  return $self->pg->db->query($query, @args) unless $cb;
  $self->pg->db->query($query, @args, sub {
    my ($db, $err, $results) = @_;
    $self->$cb($err, $results);
  });
}

sub enable_jobs {
  my ($self, $jobs, $cb) = @_;
  $jobs = [$jobs ? $jobs : ()] unless ref $jobs;
  return unless @$jobs;
  my $minion = $self->minion;
  for my $id (@$jobs) {
    $self->minion->job($id)->retry({queue => 'default'});
  }
  my $query = <<'  SQL';
    UPDATE minion_banana_jobs
    SET status='enabled'
    WHERE id=any(?) AND status='waiting'
  SQL
  return $self->pg->db->query($query, $jobs)->rows unless $cb;
  $self->pg->db->query($query, $jobs, sub {
    my ($db, $err, $results) = @_;
    $self->$cb($err, $results ? $results->rows : undef);
  });
}

sub jobs_ready {
  my $cb = (ref $_[-1] && ref $_[-1] eq 'CODE') ? pop : undef;
  my ($self, $group) = @_; # $group is optional
  my $query = <<'  SQL';
    SELECT jobs.id FROM minion_banana_jobs jobs
    LEFT JOIN minion_banana_job_deps parents ON jobs.id=parents.job_id
    LEFT JOIN minion_banana_jobs parent ON parents.parent_id=parent.id
    WHERE
      jobs.status='waiting'
      AND (parent.status IS NULL OR parent.status='finished')
      AND (jobs.group_id = $1 OR $1 IS NULL)
    GROUP BY jobs.id
  SQL
  return $self->pg->db->query($query, $group)->arrays->flatten->to_array unless $cb;
  $self->pg->db->query($query, $group, sub {
    my ($db, $err, $results) = @_;
    return $self->$cb($err, undef) if $err;
    $self->$cb(undef, $results->arrays->flatten->to_array);
  });
}

sub enqueue {
  my ($self, $jobs) = @_;
  my $group = $self->pg->db->query("INSERT INTO minion_banana_groups DEFAULT VALUES RETURNING id")->hash->{id};
  $self->_enqueue($group, $jobs, []);
  return $group;
}

sub _enqueue {
  my ($self, $group, $job, $parents) = @_;
  $parents ||= [];
  if ($job->$_isa('Minion::Banana::Sequence')) {
    for my $j ( @$job ) {
      $parents = $self->_enqueue($group, $j, $parents);
    }
    return $parents;
  } elsif ($job->$_isa('Minion::Banana::Parallel')) {
    my @ids;
    for my $j ( @$job ) {
      my $ids = $self->_enqueue($group, $j, $parents);
      push @ids, @$ids;
    }
    return \@ids;
  } else {
    $job->[2]{queue} = 'waitdeps';
    my $id = $self->minion->enqueue(@$job);
    $self->pg->db->query('INSERT INTO minion_banana_jobs (id, group_id) VALUES  (?,?)', $id, $group);
    $self->pg->db->query(<<'    SQL', $id, $parents) if @$parents;
      INSERT INTO minion_banana_job_deps (job_id, parent_id)
      SELECT ?, parent
      FROM unnest(?::bigint[]) g(parent)
    SQL
    return [$id];
  }
}

sub _worker {
  my ($minion, $worker) = @_;
  $worker->on(dequeue => \&_dequeue);
}

sub _dequeue {
  my ($worker, $job) = @_;
  $job->on(finished => \&_finished);
  $job->on(failed   => \&_failed);
}

sub _finished {
  my ($job, $result) = @_;
  $job->app->minion_banana->notify($job, 1);
}

sub _failed {
  my ($job, $err) = @_;
  $job->app->minion_banana->notify($job, 0);
}

sub notify {
  my ($self, $job, $success) = @_;
  $self->pg->pubsub->notify(minion_banana => j({job => $job->id, success => $success ? \1 : \0}));
}

sub group_status {
  my ($self, $group, $cb) = @_;
  my $sql = <<'  SQL';
    SELECT job.id, job.status, json_agg(parents.parent_id) AS parents
    FROM minion_banana_groups groups
    LEFT JOIN minion_banana_jobs job ON job.group_id=groups.id
    LEFT JOIN minion_banana_job_deps parents ON job.id=parents.job_id
    WHERE groups.id=?
    GROUP BY job.id, parents.parent_id
  SQL
  return $self->pg->db->query($sql, $group)->hashes unless $cb;
  $sql->pg->db->query($sql, $group, sub {
    my ($db, $err, $results) = @_;
    return $cb->($err, undef) if $err;
    $cb->(undef, $results->hashes);
  });
}

{
  package Minion::Banana::Parallel;
  use Mojo::Base 'Mojo::Collection';

  package Minion::Banana::Sequence;
  use Mojo::Base 'Mojo::Collection';
}

sub parallel { Minion::Banana::Parallel->new(@_) }
sub sequence { Minion::Banana::Sequence->new(@_) }

'BA-NA-NA!';

__DATA__

@@ minion_banana
-- 1 up
CREATE TABLE minion_banana_groups (
  id BIGSERIAL PRIMARY KEY,
  created TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE minion_banana_jobs (
  id BIGINT PRIMARY KEY,
  group_id BIGINT REFERENCES minion_banana_groups(id) ON DELETE CASCADE,
  status TEXT DEFAULT 'waiting'
);
CREATE TABLE minion_banana_job_deps (
  job_id BIGINT REFERENCES minion_banana_jobs(id) ON DELETE CASCADE,
  parent_id BIGINT REFERENCES minion_banana_jobs(id),
  UNIQUE (job_id, parent_id)
);
--1 down;
DROP TABLE IF EXISTS minion_banana_job_deps;
DROP TABLE IF EXISTS minion_banana_jobs;
DROP TABLE IF EXISTS minion_banana_groups;

