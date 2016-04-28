use Mojolicious::Lite;

use Importer 'Minion::Banana' => qw/sequence parallel/;

plugin 'Minion' => {Pg => 'postgresql://hubble:hubble@/minion'};
plugin 'Minion::Banana';

app->minion->add_task(eat => sub { sleep 1; my $fruit = $_[1] || 'banana'; say "$fruit: Om Nom Nom" });

helper load => sub {
  shift->minion_banana->enqueue(
    sequence(
      ['eat'],
      parallel(
        [eat => ['pineapple']],
        [eat => ['apple']],
      ),
      ['eat' => ['orange']],
      ['eat' => ['banananana']],
    )
  );
};

app->start;

