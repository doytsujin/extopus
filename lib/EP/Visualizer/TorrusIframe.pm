package EP::Visualizer::TorrusIframe;

=head1 NAME

EP::Visualizer::TorrusIframe - provide access to appropriate torrus pages via a proxy

=head1 SYNOPSIS

 *** VISUALIZER: iframe ***
 module=TorrusIframe
 title=Torrus
 caption="$R{prod} $R{inv_id} $R{device_name}:$R{port}"

=head1 DESCRIPTION

The proxy will only deliver pages with a valid hash. As it ships html pages,
it can rewrite internal img refs to include appropriate hash keys.

This visualizer will match any records that have the following attributes:

 torrus.server
 torrus.url-prefix
 torrus.nodeid

=head1 METHODS

all the methods from L<EP::Visualizer::base>. As well as these:

=cut

use Mojo::Base 'EP::Visualizer::base';
use Mojo::Util qw(hmac_md5_sum url_unescape);
use Mojo::URL;
use Mojo::UserAgent;
use EP::Exception qw(mkerror);


has 'hostauth';
#has 'view' => 'expanded-dir-html';
has view    => 'iframe-rrd';


sub new {
    my $self = shift->SUPER::new(@_);
    $self->root('/torrusIframe_'.$self->instance);
    $self->addProxyRoute();
    return $self;
}

sub matchRecord {
    my $self = shift;
    my $type = shift;
    return unless $type eq 'single';
    my $rec = shift;
    for (qw(torrus.nodeid torrus.tree-url)){
        return unless defined $rec->{$_};
    };
    my $url = $rec->{'torrus.tree-url'};
    my $leaves = $self->getLeaves($url,$rec->{'torrus.nodeid'});
    my $view = $self->view;
    my @views;
    for my $token (sort { ($leaves->{$b}{precedence} || 0) <=> ($leaves->{$a}{precedence} || 0) } keys %$leaves){
        my $leaf = $leaves->{$token};
        next unless ref $leaf; # skip emtpy leaves
        my $nodeid = $leaf->{nodeid} or next; # skip leaves without nodeid
        my $hash = $self->calcHash($url,$nodeid,$view);
        $self->app->log->debug('adding '.$leaf->{comment},$leaf->{nodeid});
        my $src = Mojo::URL->new($self->root);
        $src->query(
            hash => $hash,
            nodeid => $nodeid,
            view => $view,
            url => $url
        );

        push @views, {
            visualizer =>  'iframe',
            instance => $self->instance,
            title => $self->cfg->{title},
            caption => $self->caption($rec),
            arguments => {
                src => $src->to_string,
                title => $leaf->{comment},
            }
        }
    };
    return @views;
}

=head2 getLeaves(treeurl,nodeid)

pull the list of leaves from torrus

=cut

sub getLeaves {
    my $self = shift;
    my $tree_url = shift;
    my $nodeid = shift;
    my $url = Mojo::URL->new($tree_url);
    $url->query(
        nodeid => $nodeid,
        view=> 'rpc',
        RPCCALL => 'WALK_LEAVES',
        GET_PARAMS => 'precedence',
    );
    $self->app->log->debug("getting ".$url->to_string);
    my $tx = Mojo::UserAgent->new->get($url);
    if (my $res=$tx->success) {
        if ($res->headers->content_type =~ m'application/json'i){
            my $ret = eval { decode_json($res->body) };
            if ($@){
                $log->error("JSON decode Problem:".$@);
                return {};
            }
            if ($ret->{success}){
                return $ret->{data};
            } else {
                die mkerror(7534,$ret->{error} || "unknown error while fetching data from torrus");
            }
        }
        else {
            $self->app->log->error("Fetching ".$url->to_string." returns ".$res->headers->content_type);
            die mkerror(39944,"expected torrus to return and application/json result, but got ".$res->headers->content_type);
        }
    }
    else {
        my $error = $tx->error;
        $self->app->log->error("Fetching ".$url->to_string." returns $error->{message}");
        die mkerror(48877,"fetching Leaves for $nodeid from torrus server: $error->{message}");
    }
}

=head2 addProxyRoute()

create a proxy route with the given properties of the object

=cut

sub addProxyRoute {
    my $self = shift;
    my $routes = $self->app->routes;

    $routes->get( $self->app->prefix.$self->root, sub {
        my $ctrl = shift;
        my $req = $ctrl->req;
        my $hash =  $req->param('hash');
        my $url = $req->param('url');
        my $pxReq =  Mojo::URL->new($url);
        my $nodeid = $req->param('nodeid');
        my $view = $req->param('view');
        my $newHash = $self->calcHash($url,$nodeid,$view);
        if ($hash ne $newHash){
            $ctrl->render(
                 status => 401,
                 text => "Supplied hash ($hash) does not match our expectations",
            );
            $self->log->warn("Request for $url?nodeid=$nodeid;view=$view denied ($hash ne $newHash)");
            return;
        }
        my $baseUrl = $pxReq->to_string;
        $pxReq->query(nodeid=>$nodeid,view=>$view);
        if ($self->hostauth){
            $pxReq->query({hostauth=>$self->hostauth});
        }
        $self->app->log->debug("Fetching ".$pxReq->to_string);
        my $tx = $ctrl->ua->get($pxReq);
        if (my $res=$tx->success) {
           my $body;
           if ($res->headers->content_type =~ m'text/html'i){
              my $dom = $res->dom;
              $self->signImgSrc($baseUrl,$dom);
              $body = $dom->to_xml;
           }
           else {
              $body = $res->body;
           }
           my $rp = Mojo::Message::Response->new;
           $rp->code(200);
           $rp->headers->content_type($res->headers->content_type);
           $rp->headers->content_type($res->headers->last_modified);
           $rp->body($body);
           $ctrl->tx->res($rp);
           $ctrl->rendered;
        }
        else {
            my $error = $tx->error;
            $ctrl->render(
                status => $error->{code},
                text => $error->{message}
            );
        }
    });
    return;
}

=head2 signImgSrc(target,res)

Sign all image urls pointing to our server.

=cut

sub signImgSrc {
    my $self = shift;
    my $pageUrl = Mojo::URL->new(shift);
    my $dom = shift;
    my $root = $self->root;
    $dom->find('img[src]')->each( sub {
        my $attrs = shift->attrs;
        my $src = Mojo::URL->new($attrs->{src});
        if (not $src->authority){
            my $nodeid = $src->query->param('nodeid');
            my $view = $src->query->param('view');

            $src->query(Mojo::Parameters->new);
            # first the scheme and then the authority (user:host:port)
            $src->scheme($pageUrl->scheme);
            $src->authority($pageUrl->authority);
            if ($src->path !~ m|^/|){
                $src->path($pageUrl->path.'/../'.$src->path);
            }
            my $url = $src->to_abs;
            my $hash = $self->calcHash($url,$nodeid,$view);

            my $newSrc = Mojo::URL->new();
            $newSrc->path($self->root);
            $newSrc->query(
                hash => $hash,
                nodeid => $nodeid,
                view => $view,
                url => $url
            );
            if ($self->hostauth){
                $newSrc->query({hostauth=>$self->hostauth});
            }
            $self->app->log->debug('img[src] in '.$attrs->{src});
            $attrs->{src} = $newSrc->to_string;
            # I guess to to_xml method of the dom re-escapes the urls again ...
            # without this they end up being double escaped
            url_unescape $attrs->{src};
            $self->app->log->debug('img[src] out '.$attrs->{src});
        }
    });
    return;
}

1;

__END__

=back

=head1 LICENSE

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=head1 COPYRIGHT

Copyright (c) 2011 by OETIKER+PARTNER AG. All rights reserved.

=head1 AUTHOR

S<Tobias Oetiker E<lt>tobi@oetiker.chE<gt>>

=head1 HISTORY

 2010-11-04 to 1.0 first version

=cut

# Emacs Configuration
#
# Local Variables:
# mode: cperl
# eval: (cperl-set-style "PerlStyle")
# mode: flyspell
# mode: flyspell-prog
# End:
#
# vi: sw=4 et
