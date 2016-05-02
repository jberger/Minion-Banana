use Mojo::Base -strict;

use Importer 'Minion::Banana' => qw/parallel sequence/;
use Mock::MonkeyPatch;
use Mojo::Util 'dumper';
use Test::More;

my $enqueue_group = Mock::MonkeyPatch->patch(
  'Minion::Banana::_enqueue_group' => sub { return 1 }
);
our ($next_job_id, @jobs);
my $enqueue_job = Mock::MonkeyPatch->patch(
  'Minion::Banana::_enqueue_job' => sub {
    my ($self, $group, $job, $parents) = @_;
    my $id = $next_job_id++;
    push @jobs, [$id, $job->[0], [sort @$parents]];
    return [$id];
  }
);

sub reset_mocks {
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  fail '_enqueue_group was not called' unless $enqueue_group->called;
  fail '_enqueue_job was not called'   unless $enqueue_job->called;
  $_->reset for ($enqueue_group, $enqueue_job);
}

my $banana = Minion::Banana->new;

subtest 'simple sequence' => sub {
  local @jobs;
  local $next_job_id = 1;

  $banana->enqueue(
    sequence(['one'],['two'],['three']),
  );

  is_deeply(\@jobs, [
    [1, 'one', []],
    [2, 'two', [1]],
    [3, 'three', [2]],
  ]);

  reset_mocks;
};

subtest 'simple parallel' => sub {
  local @jobs;
  local $next_job_id = 1;

  $banana->enqueue(
    parallel(['one'],['two'],['three']),
  );

  is_deeply(\@jobs, [
    [1, 'one', []],
    [2, 'two', []],
    [3, 'three', []],
  ]);

  reset_mocks;
};

subtest 'sequence containing parallel' => sub {
  local @jobs;
  local $next_job_id = 1;

  $banana->enqueue(
    sequence(
      ['before'],
      parallel(['one'],['two'],['three']),
      ['after'],
    )
  );

  is_deeply(\@jobs, [
    [1, 'before', [] ],
    [2, 'one',    [1]],
    [3, 'two',    [1]],
    [4, 'three',  [1]],
    [5, 'after',  [2,3,4]],
  ]);

  reset_mocks;
};

subtest 'parallel containing sequence' => sub {
  local @jobs;
  local $next_job_id = 1;

  $banana->enqueue(
    parallel(
      ['p1'],
      sequence(['one'],['two'],['three']),
      ['p3'],
    )
  );

  is_deeply(\@jobs, [
    [1, 'p1',    [] ],
    [2, 'one',   []],
    [3, 'two',   [2]],
    [4, 'three', [3]],
    [5, 'p3',    []],
  ]);

  reset_mocks;
};

subtest 'sequence containing parallel containing sequence' => sub {
  local @jobs;
  local $next_job_id = 1;

  $banana->enqueue(
    sequence(
      ['s1'],
      parallel(
        ['p1'],
        sequence(['one'],['two'],['three']),
        ['p3'],
      ),
      ['s3'],
    )
  );

  is_deeply(\@jobs, [
    [1, 's1',    [] ],
    [2, 'p1',    [1] ],
    [3, 'one',   [1]],
    [4, 'two',   [3]],
    [5, 'three', [4]],
    [6, 'p3',    [1]],
    [7, 's3',    [2,5,6]],
  ]);

  reset_mocks;
};

done_testing;

