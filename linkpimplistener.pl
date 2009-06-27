#!usr/bin/perl
use strict;
use warnings;
use HTTP::Daemon;
use Frontier::RPC2;
use HTTP::Date;
use XML::RSS;
use LWP::Simple;

# ------USER CHANGABLE VARIABLES HERE -------

my $listeningport = "8888";

# -------------------------------------------

my $methods = { 'updateFeed' => \&updateFeed };
our $host = "";

# --------------- Start the server up ------------------------

my $listen_socket = HTTP::Daemon->new(
    LocalPort => $listeningport,
    Listen    => 20,
    Proto     => 'tcp',
    Reuse     => 1
);

die "Can't create a listening socket: $@" unless $listen_socket;

while ( my $connection = $listen_socket->accept ) {
    $host = $connection->peerhost;
    interact($connection);
    $connection->close;
}

# ------------- The Interact subroutine, as called when a peer connects

sub interact {
    my $sock = shift;
    my $req;
    eval { $req = $sock->get_request; };

    # Check to see if the contact is both xml and to the right path.
    if (   $req->header('Content-Type') eq 'text/xml'
        && $req->url->path eq '/RPC2' )
    {
        my $message_content = ( $req->content );
        if ($main::Fork) {
            my $pid = fork();
            unless ( defined $pid ) {

                #  check this response
                my $res = HTTP::Response->new( 500, 'Internal Server Error' );
                $sock->send_status_line();
                $sock->send_response($res);
            }
            if ( $pid == 0 ) {
                $sock->close;
                $main::Fork->();
                exit;
            }

            $main::Fork = undef;
        }

        my $conn_host = gethostbyaddr( $sock->peeraddr, AF_INET )
          || $sock->peerhost;

        my $res = HTTP::Response->new( 200, 'OK' );
        $res->header(
            date         => time2str(),
            Server       => 'PubSubServer',
            Content_Type => 'text/xml',
        );

        $res->content($res_xml);
        $sock->send_response($res);

        # ---------------------------------------------------------------------

        # ---- updateFeed -----

        sub updateFeed {

            my ($url) = @_;

            # Create new instance of XML::RSS

            my $rss = new XML::RSS;

            # Parse the $url and stick it in $rss

            my $feed_to_parse = get($url);
            $rss->parse($feed_to_parse);

            # Decide on name for outputfile

            my $outputfile = "$rss->{'channel'}->{'title'}.html";
            $outputfile =~ s/ /_/g;

            # Open the output file

            open( OUTPUTFILE, ">$outputfile" );

            # Print the Channel Title

            print OUTPUTFILE '<div id="channel_link"><a href="';
            print OUTPUTFILE "$rss->{'channel'}->{'link'}";
            print OUTPUTFILE '">';
            print OUTPUTFILE "$rss->{'channel'}->{'title'}</a></div>\n";

            # Print channel image, checking first if it exists

            if ( $rss->{'image'}->{'link'} ) {
                print OUTPUTFILE '<div id="channel_image"><a href="';
                print OUTPUTFILE "$rss->{'image'}->{'link'}";
                print OUTPUTFILE '">';
                print OUTPUTFILE '<img src="';
                print OUTPUTFILE "$rss->{'image'}->{'url'}";
                print OUTPUTFILE '" alt="';
                print OUTPUTFILE "$rss->{'image'}->{'title'}";
                print OUTPUTFILE '"/></a>';
                print OUTPUTFILE "\n";
            }

            # Print the channel items

            print OUTPUTFILE '<div id="linkentries">';
            print OUTPUTFILE "\n";

            foreach my $item ( @{ $rss->{'items'} } ) {
                next
                  unless defined( $item->{'title'} )
                  && defined( $item->{'link'} );
                print OUTPUTFILE '<li><a href="';
                print OUTPUTFILE "$item->{'link'}";
                print OUTPUTFILE '">';
                print OUTPUTFILE "$item->{'title'}</a><BR>\n";
            }
            print OUTPUTFILE "</div>\n";

            # If there's a textinput element...

            if ( $rss->{'textinput'}->{'title'} ) {
                print OUTPUTFILE '<div id="textinput">';
                print OUTPUTFILE '<form method="get" action="';
                print OUTPUTFILE "$rss->{'textinput'}->{'link'}";
                print OUTPUTFILE '">';
                print OUTPUTFILE "$rss->{'textinput'}->{'description'}<br/>/n";
                print OUTPUTFILE '<input type="text" name="';
                print OUTPUTFILE "$rss->{'textinput'}->{'name'}";
                print OUTPUTFILE '"><br/>/n';
                print OUTPUTFILE '<input type="submit" value="';
                print OUTPUTFILE "$rss->{'textinput'}->{'title'}";
                print OUTPUTFILE '"></form>';
                print OUTPUTFILE '</div>';
            }

            # If there's a copyright element...

            if ( $rss->{'channel'}->{'copyright'} ) {
                print OUTPUTFILE '<div id="copyright">';
                print OUTPUTFILE "$rss->{'channel'}->{'copyright'}</div>";

            }

            # Close the OUTPUTFILE

            close(OUTPUTFILE);
        }

        # ----------------

    }
}
