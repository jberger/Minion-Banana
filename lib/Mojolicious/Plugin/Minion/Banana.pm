package Mojolicious::Plugin::Minion::Banana;

use Mojo::Base 'Mojolicious::Plugin';

use Minion::Banana;

sub register {
  my ($plugin, $app, $config) = @_;
  
  Minion::Banana->new(minion => $app->minion)->attach;
}

1;

