use Mojo::Base -strict;

use Test::More;

use Mojolicious;
use Importer 'Minion::Banana' => qw/parallel sequence/;

plan skip_all => 'Set MINION_BANANA_TEST_ONLINE to perform this test'
  unless my $url = $ENV{MINION_BANANA_TEST_ONLINE};

my $app = Mojolicious->new;
$app->plugin(Minion => {Pg => $url});
$app->plugin('Minion::Banana');

my $minion = $app->minion;
my $banana = $app->minion_banana;
$banana->unsubscribe('ready'); # prevent auto-enable;

$minion->add_task('doit' => sub { });

my $group = $banana->enqueue(
  sequence([doit => ['zero']], [doit => ['one']], [doit => ['two']]),
);
my $status = $banana->group_status($group);
my @id = map { $_->{id} } @$status;
my $expect = [
  {id => $id[0], parents => [undef],  status => 'waiting'},
  {id => $id[1], parents => [$id[0]], status => 'waiting'},
  {id => $id[2], parents => [$id[1]], status => 'waiting'},
];

# helper to run one job and return the new ready jobs from the event
sub perform {
  my $ready;
  $banana->once(ready => sub {
    (undef, $ready) = @_;
    Mojo::IOLoop->stop;
  });
  Mojo::IOLoop->next_tick(sub { $minion->perform_jobs });
  $banana->manage;
  return $ready;
}

# check initial state
my $ready = $banana->jobs_ready($group);
is_deeply $ready, [$id[0]], 'correct job ready';
my $job = $minion->job($id[0]);
is_deeply $status, $expect, 'correct status entries';

# perform zero
$ready = perform();
$expect->[0]{status} = 'finished';

# check state after zero
is_deeply $ready, [$id[1]], 'correct job ready';
$job = $minion->job($id[1]);
is_deeply $job->args, ['one'], 'got correct job';

$status = $banana->group_status($group);
is_deeply $status, $expect, 'correct status entries';

# perform one
$ready = perform();
$expect->[1]{status} = 'finished';

# check state after one
is_deeply $ready, [$id[2]], 'correct job ready';
$job = $minion->job($id[2]);
is_deeply $job->args, ['two'], 'got correct job';

$status = $banana->group_status($group);
is_deeply $status, $expect, 'correct status entries';

# perform two
$ready = perform();
$expect->[2]{status} = 'finished';

# complete after two
is_deeply $ready, [], 'no jobs ready (complete)';
$status = $banana->group_status($group);
is_deeply $status, $expect, 'correct status entries';

done_testing;

