#!/usr/bin/perl

use diagnostics;
use warnings;

use XML::RSS;
use XML::Simple;
use LWP::Simple;
use Frontier::Client;
use Frontier::RPC2;
use File::Copy;
use SOAP::Lite;
use LWP::UserAgent;

# User changable variables

my $logging         = "1";
my $logfile         = "logfile.txt";
my $pubsublog       = "pubsub.txt";
my $includefile     = "feeds.shtml";
my $tempincludefile = "feeds.shtml.tmp";

my $syndic8_userid      = "XXXXXXXXXXXXXX";
my $syndic8_password    = "XXXXX";
my $syndic8_list_id     = "0";
my $syndic8_XMLRPC_path = "http://www.syndic8.com:80/xmlrpc.php";

my $pubsub_listening_procedure = "updatedFeed";
my $pubsub_port                = "8889";
my $pubsub_path                = "/RPC2";
my $pubsub_protocol            = "xml-rpc";

my $content;
my $file;
my $line;

our $url;
our $retrieved_feed;
our $feed_spec;

#####################################################

logger("\n Program started. Let's go!\n");

# First we need to strim the pubsub records and remove all the old entries.

# Work out the time 25 hours ago (1 hour = 3600 seconds, so 25 hours = 90000 seconds)
my $oldestpossibletime = time() - 90000;

logger(
"The oldest allowable subscription cannot have been made earlier than $oldestpossibletime"
);

# Open the subscriber list created by pubSubListener and stick it in an array.
open( PUBSUBLIST, "<$pubsublog" );
my @lines = <PUBSUBLIST>;
close(PUBSUBLIST);

# Clear the subscriber list
unlink($pubsublog) or die "Can't delete the data file\n";
logger("Old Subscription list deleted");

# We need to prevent the file being empty, even if there are no subscriptions, so:
open( NEWPUBSUBLIST, ">$pubsublog" );
print NEWPUBSUBLIST
  "This holds the details of all your subscriptions , 0000001\n";

# Go through each line, splitting it back into the right variables.
foreach $line (@lines) {
    my ( $rssUrl, $time ) = split ( /,/, "$line" );

# If the time the notification request was made ($time) is later than 25 hours ago
# ($oldestpossibletime) then stick that line back into the data file.

    if ( $time > $oldestpossibletime ) {
        print NEWPUBSUBLIST "$line\n";
    }
}
logger("New PubSublist written");

close(NEWPUBSUBLIST);

# Now, we reopen the pubsublog, and load it as a string for use later
open( PUBSUB, "$pubsublog" );
$/ = '';
my $content_of_pubsublog = <PUBSUB>;

# and we finally close the filehandle.
close(PUBSUB);

##########

# Use xmlrpc to ask for list of feeds from syndic8, and create object from result.
my $syndic8_xmlrpc_call = Frontier::Client->new(
    url         => $syndic8_XMLRPC_path,
    debug       => 0,
    use_objects => 1
);

my $syndic8_xmlrpc_returned_subscriber_list = $syndic8_xmlrpc_call-> call(
    'syndic8.GetSubscribed', $syndic8_userid,
    $syndic8_password,       $syndic8_list_id
  )
  or die "Cannot retrieve Syndic8 list";
logger("Retrieved Syndic8 subscription list");

# Place the dataurls from the subscriber list into an array
my @edited_subscribed_feeds_list =
  map { $_->{dataurl} } @$syndic8_xmlrpc_returned_subscriber_list;

# Take the next line from the array of DataURLs
foreach $url (@edited_subscribed_feeds_list) {
    logger("Now working with $url");

    # Check the feed is not on the list of subscribed-to feeds
    if ( $content_of_pubsublog =~ m/$url/i ) {
        logger(
"Subscription already present, it seems. Excellent. I shall get on with the next one."
        );

        #We leave the main loop and move onto the next URL
    }
    else {

        # Retrieve the RSS feed
        $retrieved_feed = get($url);
        logger("Retrieved Feed from $url");

        # Examine for <cloud>
        if ( $retrieved_feed =~ m/<cloud/ ) {
            &subscribetorss092feed;
        }
        elsif ( $retrieved_feed =~ m/<cp:server/ ) {
            &subscribetorss10feed;
        }
        else {
            logger("There is no cloud element");

            # Stick it through print_html, with an error trap here
            eval { &print_html };
            logger("The parsing choked on $url with this error\n $@ \n") if $@;
        }
    }

    # Go to the next url in the list
}

### Replace the include file with the temporary one, and do it fast!
move( "$tempincludefile", "$includefile" );

### Clean up and exit the program
logger("We're all done here for now. Exiting Program.\n\n");

END;

######
## THE SUBROUTINES
######

sub subscribetorss092feed {

    logger("We're not subscribed, so I shall attempt to subscribe to the $url");

# First we must parse the <cloud> element with $retrieved_feed This is in a set format:
# e.g <cloud domain="www.newsisfree.com" port="80" path="/RPC" registerProcedure="hpe.rssPleaseNotify" protocol="xml-rpc" />
# We'll do this with XML::Simple

    my $parsed_xml = XMLin($retrieved_feed);

    my $cloud_domain            = $parsed_xml->{channel}->{cloud}->{domain};
    my $cloud_port              = $parsed_xml->{channel}->{cloud}->{port};
    my $cloud_path              = $parsed_xml->{channel}->{cloud}->{path};
    my $cloud_registerProcedure =
      $parsed_xml->{channel}->{cloud}->{registerProcedure};
    my $cloud_protocol = $parsed_xml->{channel}->{cloud}->{protocol};

    logger("We have retrieved the PubSub data from the RSS 0.92 feed.");
    logger("The cloud domain is $cloud_domain");
    logger("The port is $cloud_port");
    logger("The path is $cloud_path");
    logger("The port is $cloud_registerProcedure");
    logger("The protocol is $cloud_protocol");

# The protocol is all important. We need to differentiate between SOAP users and those who like XML-RPC

    if ( $cloud_protocol eq "xml-rpc" ) {

        # Marvellous. That done, we spawn a new xml:rpc client
        my $pubsub_call = Frontier::Client->new(
            url         => "http://$cloud_domain:$cloud_port$cloud_path",
            debug       => 0,
            use_objects => 1
        );

        # Then call the remote procedure with the rss url, as per the spec

        $pubsub_call->call( $cloud_registerProcedure,
            $pubsub_listening_procedure, $pubsub_port, $pubsub_path,
            $cloud_protocol, $url );

        logger("I've asked for the subscription");
    }
    elsif ( $cloud_protocol eq "soap" ) {

        # Initialise the SOAP interface
        my $service =
          SOAP::Lite->uri("http://$cloud_domain:$cloud_port$cloud_path");

        # Run the search
        my $result = $service->call(
            $cloud_registerProcedure => (
                $pubsub_listening_procedure, $pubsub_port,
                $pubsub_path,                $cloud_protocol,
                $url
            )
        );

    }
    else {
        logger("I can't work out what protocol this guy wants. ho hum");
        return 1;
    }

    # Now add the url, and the time it was made to the pubsublog
    open( PUBSUBLOG, ">>$pubsublog" );
    my $time = time();
    print PUBSUBLOG "$url , $time\n";
    close PUBSUBLOG;

    # That's it: return to the next one in the list.
}

#######
#######

sub subscribetorss10feed {

    logger("We're not subscribed, so I shall attempt to subscribe to the $url");

    #We need to work out which URL to send the request to.

    my $request_url = $rss->{'channel'}->{'link'}->{'cp:server'};
    logger("The Request URL is $request_url");

    #We're going to use LWP::UserAgent for this
    #So, we need to fire up a new UserAgent implementation

    logger("Creating the UserAgent");
    my $ua = LWP::UserAgent->new;

    #and give it a nice name

    $ua->agent( Personal Pubsub 1.0 );

    #And then do the requesting,
    #Remembering that we only need to pass the URL of the listener,
    #and the URL of the feed we want to have running

    $ua->request( POST $request_url,
        [ responder => $responder, target => $url ] );
    logger("Subscription request made");

}

######
######

sub logger {
    if ( $logging eq "1" ) {
        open( LOG, ">>$logfile" );
        print LOG @_, "\n";
        close LOG;
        return 1;
    }
    else {
        return 1;
    }

}

######
######

sub includefile {
    ## In order to prevent a race condition, or duplicate feeds, we can't just append directly to the include file itself
    ## so we create a temporary include file, and then replace the real one with the temporary one right at the end of the program
    open( INCLUDEFILE, ">>$tempincludefile" );
    print INCLUDEFILE '<!--#include file="'
      . $outputfile . '" -->' . "\n" . "<br/>" . "\n";
    close INCLUDEFILE;
    return 1;
}

#######
#######

sub print_html {

    # Create new instance of XML::RSS
    my $rss = new XML::RSS;

    # Parse the $url and stick it in $rss
    logger("Now trying to parse $url");
    my $feed_to_parse = get($url);
    $rss->parse($feed_to_parse);

    # Decide on name for outputfile
    our $outputfile = "$rss->{'channel'}->{'title'}.html";
    $outputfile =~ s/ /_/g;

    # Open the output file
    logger("I'm going to call the output file $outputfile");
    open( OUTPUTFILE, ">$outputfile" );

    # Print the Channel Title
    print OUTPUTFILE '<div class="channel_link">' . "\n" . '<a href="';
    print OUTPUTFILE "$rss->{'channel'}->{'link'}";
    print OUTPUTFILE '">';
    print OUTPUTFILE "$rss->{'channel'}->{'title'}</a>\n</div>\n";

    # Print channel image, checking first if it exists
    if ( $rss->{'image'}->{'link'} ) {
        print OUTPUTFILE '<div class="channel_image">' . "\n" . '<a href="';
        print OUTPUTFILE "$rss->{'image'}->{'link'}";
        print OUTPUTFILE '">' . "\n";
        print OUTPUTFILE '<img src="';
        print OUTPUTFILE "$rss->{'image'}->{'url'}";
        print OUTPUTFILE '" alt="';
        print OUTPUTFILE "$rss->{'image'}->{'title'}";
        print OUTPUTFILE '"/>' . "\n</a>\n</div>";
        print OUTPUTFILE "\n";
    }

    # Print the channel items
    print OUTPUTFILE '<div class="linkentries">' . "\n" . "<ul>";
    print OUTPUTFILE "\n";

    foreach my $item ( @{ $rss->{'items'} } ) {
        next unless defined( $item->{'title'} ) && defined( $item->{'link'} );
        print OUTPUTFILE '<li><a href="';
        print OUTPUTFILE "$item->{'link'}";
        print OUTPUTFILE '">';
        print OUTPUTFILE "$item->{'title'}</a></li>\n";
    }
    print OUTPUTFILE "</ul>\n</div>\n";

    # Close the OUTPUTFILE

    close(OUTPUTFILE);
    logger("and lo $outputfile has been written.");

    # Add to the include-file
    includefile($outputfile);
}
