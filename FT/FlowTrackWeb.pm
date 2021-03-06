package FT::FlowTrackWeb;

use strict;
use warnings;
use Log::Log4perl qw(get_logger);
use Carp;

use Mojo::Base 'Mojolicious';
use Mojolicious::Static;
use Data::Dumper;
use vars '$AUTOLOAD';

sub startup
{
    my $self = shift();

    # Serve up the static pages
    $self->static( Mojolicious::Static->new() );
    push( @{ $self->static->paths }, './html' );

    my $r = $self->routes;

    $r->route('/')->name('index')->to( controller => 'main', action => 'indexPage' );

    $r->route('/FlowsForLast/:timerange')->to( controller => 'main', action => 'simpleFlows' );
    $r->route('/json/FlowsForLast/:timerange')->to( controller => 'main', action => 'simpleFlowsJSON' );

    return;
}

1;
