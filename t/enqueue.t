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
    push @jobs, [$id, $job->[0], $parents];
    return [$id];
  }
);

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
};

done_testing;

