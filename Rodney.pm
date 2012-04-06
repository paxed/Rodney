package Rodney;

use strict;
use warnings;

use diagnostics;  # For development
use vars qw($VERSION @ISA @EXPORT);
use Carp;
use POE;
use POE::Component::IRC;
use POE::Wheel::FollowTail;
use POSIX qw( setsid );
use DBI;
use URI::Escape;
use File::Basename;
use IO::Socket::INET;


use Config;
$Config{useithreads} or die('Recompile Perl with threads to run this program.');
use threads;
use threads::shared;
use Thread::Queue;

my $querythread_input  = Thread::Queue->new(); # format: channel\tnick\tresult
my @querythread_output :shared = (); # format: channel\tnick\tresult

my $irc;
my $kernel;

require Exporter;


@ISA     = qw(Exporter);
@EXPORT  = qw();
$VERSION = '0.04';


use nhconst;
do "librodney.pm";
use learndb;
use seendbi;
use nhbugs;
use messages;
use nickidlist;
use ignorance;
use redditrss;


my @nh_monsters;
my @nh_objects;

my $nh_dumppath;
my $nh_dumpurl;
my $userdata_ttyrec;
my $userdata_ttyrec_puburl;

my $ignorance = Ignorance->new();
my $learn_db = LearnDB->new();
my $seen_db = SeenDB->new();
my $buglist_db = NHBugsDB->new();
my $user_messages_db = Messages->new();
my $admin_nicks = NickIdList->new();
my $reddit_rss = RedditRSS->new();
my $dbh;

my @recent_nicks;

my @wiki_datagram_queue = ();

my $xlogfiledb;
my $shorturldb;
my $dgldb;
my $nethackwikidb;

use constant DATAGRAM_MAXLEN => 1024;


sub recent_nicks_add {
    my $nick = shift;
    return if ( grep {lc($_) eq lc($nick)} @recent_nicks );
    shift(@recent_nicks) if ($#recent_nicks >= 4);
    push(@recent_nicks, $nick);
}

sub recent_nicks_getrnd {
    return "no-one" if ($#recent_nicks == -1);
    return $recent_nicks[rand(@recent_nicks)];
}


sub db_connect {
    my ($self) = @_;
    if (!($dbh = DBI->connect("dbi:".$xlogfiledb->{dbtype}.":".$xlogfiledb->{db}.":localhost",$xlogfiledb->{user},$xlogfiledb->{pass},{AutoCommit => 1, PrintError => 1}))) {
	debugprint("Cannot connect to xlogfile db.");
	undef $dbh;
    }
}

sub db_disconnect {
    if ($dbh) {
	$dbh->commit();
	$dbh->disconnect();
    }
}

sub player_logfile {
    my ($self, $regex) = @_;
    db_connect($self);

    my @lines;

    return ("Xlogfile db disabled.") if (!$dbh);

    my $sth = $dbh->prepare("SELECT * FROM xlogfile WHERE name like ".$dbh->quote($regex));
    $sth->execute();

    while (my $dbdata = $sth->fetchrow_hashref()) {
	my @tmpl;
	foreach my $k (keys %$dbdata) {
	    push(@tmpl, $k.'='.$dbdata->{$k});
	}
	push(@lines, join(":", @tmpl));
    }

    db_disconnect();

#    my @lines = split(/\n/, `grep -i '$regex' $self->{'nh_logfile'}`);
    return @lines;
}

# Set us up the bomb
sub new {
    my $class = shift;
    my %args  = @_;
    return bless \%args, $class;
}

# Run the bot
sub run {
    my $self = shift;

    $nh_dumppath = $self->{'nh_dumppath'};
    $nh_dumpurl  = $self->{'nh_dumpurl'};

    $userdata_ttyrec = $self->{'userdata_ttyrec'};
    $userdata_ttyrec_puburl = $self->{'userdata_ttyrec_puburl'};

    $xlogfiledb = $self->{'xlogfiledb'};
    $shorturldb = $self->{'shorturldb'};
    $dgldb = $self->{'dgldb'};
    $nethackwikidb = $self->{'nethackwikidb'};

    @nh_monsters = read_textdata_file($self->{'nh_monsters_file'});
    @nh_objects = read_textdata_file($self->{'nh_objects_file'});

    $ignorance->init($self->{'ignorancefile'});
    $ignorance->load();

    debugprint("Running the bot.");

    $self->daemonize() if ($self->{'Daemonize'});

    threads->create(\&sqlquery_subthread)->detach();

    ($irc) = POE::Component::IRC->spawn()
	|| croak "Cannot create new P::C::I object!\n";

    debugprint("irc->new(nick)");

    POE::Session->create(
        object_states => [
            $self => {
#		_default         => "_poe_default_msg",
                _start           => "bot_start",
                irc_001          => "on_connect",
                irc_disconnected => "on_disco",
                irc_public       => "on_public",
                irc_msg          => "on_msg",
                irc_quit         => "on_quit",
                irc_join         => "on_join",
                irc_part         => "on_part",
                irc_mode         => "on_mode",
                irc_kick         => "on_kick",
                irc_notice       => "on_notice",
                irc_ctcp_ping    => "on_ping",
                irc_ctcp_version => "on_ver",
                irc_ctcp_finger  => "on_finger",
                irc_ctcp_page    => "on_page",
                irc_ctcp_time    => "on_time",
                irc_ctcp_action  => "on_action",
                irc_nick         => "on_nick",
                keepalive        => "keepalive",
                irc_433          => "on_nick_taken",
                irc_353          => "on_names",
                irc_dcc_request  => "on_dcc_req",
                irc_dcc_error    => "on_dcc_err",
                irc_dcc_done     => "on_dcc_done",
                irc_dcc_start    => "on_dcc_start",
                irc_dcc_chat     => "on_dcc_chat",
		d_tick		=> "on_d_tick",
		database_sync	=> "database_sync",
		buglist_update	=> "buglist_update",
		get_wiki_datagram => "on_wiki_datagram",
		handle_wiki_data => "handle_wiki_datagrams",
		handle_reddit_rss_data => "handle_reddit_rss",
		handle_querythread_out => "handle_querythread_output"
            }
        ]
    );

    debugprint("session_create");

    $poe_kernel->run();

    debugprint("run");
}

sub _poe_default_msg {
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output = ( "$event: " );

    foreach my $arg ( @$args ) {
        if ( ref($arg) eq 'ARRAY' ) {
	    push( @output, "[" . join(" ,", @$arg ) . "]" );
        } else {
	    push ( @output, "'$arg'" );
        }
    }
    print STDOUT join ' ', @output, "\n";
    return 0;
}


# Start the bot things up
sub bot_start {

    my ( $self, $session ) = @_[ OBJECT, SESSION ];

    $kernel = $_[ KERNEL ];

    debugprint("Starting Up...");

    my $socket = IO::Socket::INET->new(
        Proto     => 'udp',
        LocalPort => '55666',
	);

    die "Couldn't create server socket: $!" unless $socket;

    $irc->yield('register', 'all');
    debugprint("nick register");
    $irc->yield(
        'connect',
        {
            Debug    => $self->{'Debug'},
            Nick     => $self->{'Nick'},
            Server   => $self->{'Server'},
            Port     => $self->{'Port'},
            Username => $self->{'User'},
            Ircname  => $self->{'Ircname'}
        }
    );
    debugprint("connect...");
    $kernel->delay( 'reconnect', 20 );
    debugprint("reconnect delay");
    $self->setup_tail() if ($self->{'CheckLog'} > 0);
    debugprint("setup_tail");
    $learn_db->init($self->{'LearnDBFile'});
    debugprint("learn_db");
    $seen_db->init($self->{'SeenDBFile'});
    debugprint("seen_db");

    $user_messages_db->init($self->{'MessagesDBFile'});
    debugprint("messages_db");

    $buglist_db->init($self->{'BugCache'}, $self->{'nh_org_bugpage'});

    $reddit_rss->init('http://reddit.com/r/nethack.rss', $self->{'RSS_tstamp'});
    $kernel->delay('handle_reddit_rss_data' => 30);

    $kernel->delay('d_tick' => 10) if ($self->{'CheckLog'} > 0);
    debugprint("tick");
    $kernel->delay('database_sync' => 600);
    debugprint("db_sync");
    if ($self->{'CheckBug'} > 0) {
	$buglist_db->cache_read();
	$kernel->delay('buglist_update' => 30);
	debugprint("buglist_update");
    }

    $kernel->select_read( $socket, "get_wiki_datagram" );
    $kernel->delay('handle_wiki_data' => 20);
    $kernel->delay('handle_querythread_out' => 10);
}

############################# RODNEY STUFF

sub shorten_url {
    my $url = shift;
    return '' if (!(defined $url));

    my $dbh = DBI->connect("dbi:".$shorturldb->{dbtype}.":".$shorturldb->{db}.":localhost",$shorturldb->{user},$shorturldb->{pass},{AutoCommit => 1, PrintError => 1});
    if ($dbh) {
	my $sth = $dbh->prepare("INSERT INTO shorturl (url) VALUES (".$dbh->quote($url).")");
	if ($dbh->err()) { return $url; }
	$sth->execute();
	my $id = $dbh->{'mysql_insertid'};
	$dbh->disconnect();
	$url = 'http://url.alt.org/?'.$id;
    } else {
	debugprint("Url shortening db error.") if (!$dbh);
    }

    return $url;
}

sub mangle_sql_query {

    my @fields = ("version",
		  "points",
		  "deathdnum",
		  "deathlev",
		  "maxlvl",
		  "hp",
		  "maxhp",
		  "deaths",
		  "deathdate",
		  "birthdate",
		  "deathyear",
		  "birthyear",
		  "deathday",
		  "birthday",
		  "deathmonth",
		  "birthmonth",
		  "uid",
		  "role",
		  "race",
		  "gender",
		  "align",
		  "name",
		  "death",
		  "conduct",
		  "nconducts",
		  "turns",
		  "achieve",
		  "nachieves",
		  "realtime",
		  "starttime",
		  "endtime",
		  "gender0",
		  "align0"
	);

    my @all_param_fields = (@fields, "max", "min" ,"sort", "g", "group", "gmax", "gmin", "hide", "skip", "limit");

    my %field_renames = (
	original_gender => "gender0",
	orig_gender => "gender0",
	origgender => "gender0",
	ogender => "gender0",
	original_align => "align0",
	orig_align => "align0",
	origalign => "align0",
	starting_align => "align0",
	orig_alignment => "align0",
	starting_alignment => "align0",
	oalign => "align0",
	achievement => "achieve",
	achievements => "achieve",
	achieved => "achieve",
	class => "role",
	deathdungeon => "deathdnum",
	deathbranch => "deathdnum",
	dungeon => "deathdnum",
	dungeonbranch => "deathdnum",
	dungeonnum => "deathdnum",
	dnum => "deathdnum",
	deathlvl => "deathlev",
	deathlevel => "deathlev",
	deathlevnum => "deathlev",
	dlvl => "deathlev",
	dlev => "deathlev",
	lev => "deathlev",
	dlevel => "deathlev",
	dlevelnum => "deathlev",
	dlevelnumber => "deathlev",
	lvl => "deathlev",
	maxlev => "maxlvl",
	maxlevel => "maxlvl",
	score => "points",
	alignment => "align",
	startdate => "birthdate",
	enddate => "deathdate",
	started => "starttime",
	ended => "endtime",
	end => "endtime",
	startime => "starttime",
	killer => "death",
	numdeaths => "deaths",
	num_deaths => "deaths",
	conducts => "conduct",
	numconducts => "nconducts",
	numconduct => "nconducts",
	num_conducts => "nconducts",
	nconduct => "nconducts",
	numachieves => "nachieves",
	numachieve => "nachieves",
	num_achieves => "nachieves",
	nachievements => "nachieves",
	numachievements => "nachieves",
	num_achievements => "nachieves",
	nachieve => "nachieves",
	gametime => "turns",
	rounds => "turns",
	turn => "turns",
	playername => "name",
	player => "name"
	);

    my %param_subst = (
        "won" => "death=ascended",
        "!won" => "death!=ascended*",
	"ascended" => "death=ascended",
	"quit" => "death=quit",
	"escaped" => "death=escaped",
	"quit|escaped" => "death=~quit|escaped",
	"escaped|quit" => "death=~quit|escaped",
	"character" => "role race gender align",
	"latest" => "max=enddate max=endtime hide=endtime",
	"newest" => "max=enddate max=endtime hide=endtime"
        );

    my %simple_settings = (
	"distinct" => 0
	);

    my %deathdlev_conv = (
      dod =>        0, dungeons    => 0,
      gehennom =>   1, hell        => 1,
      mines =>	    2,
      quest =>	    3,
      sokoban =>    4, soko        => 4,
      ludios =>	    5, fort_ludios => 5,
      vlad  =>	    6,
      planes =>	    7, plane         =>  7,
      astral =>	    -5, astral_plane => -5,
      water =>	    -4, water_plane  => -4,
      fire =>	    -3, fire_plane   => -3,
      air  =>	    -2, air_plane    => -2,
      earth =>	    -1, earth_plane  => -1);

    my @operators = ("=~", "=", ">", "<", "<=", ">=", "!=", "<>", ":=", ":!=");


    my %conduct_names = (
	none => 0x0000,         nothing => 0x0000,
        foodless => 0x0001,     food    => 0x0001,   foo => 0x0001,
        vegan => 0x0002,        veg     => 0x0002,   vgn => 0x0002,
        vegetarian => 0x0004,   vgt     => 0x0004,
        atheist => 0x0008,      godless => 0x0008,   ath => 0x0008,
        weaponless => 0x0010,   weapon  => 0x0010,   wea => 0x0010, wpn => 0x0010,
        pacifist => 0x0020,     paci    => 0x0020,   pac => 0x0020,
        illiterate => 0x0040,   illit   => 0x0040,   ill => 0x0040,
        polypiles => 0x0080,    polypileless => 0x0080, ppl => 0x0080,
        polyself => 0x0100,     polyselfless => 0x0100, psf => 0x0100,
	polymorph => 0x0180,
        wishing => 0x0200,      wish    => 0x0200,   wishless => 0x0200, wis => 0x0200,
        artiwishing => 0x0400,  arti    => 0x0400,   artiwishless => 0x0400, art => 0x0400,
        genocide => 0x0800,     geno    => 0x0800,   gen => 0x0800);

    my %achieve_names = (
	get_bell            => 0x0001, bell            => 0x0001,
	enter_gehennom      => 0x0002, gehennom        => 0x0002, hell         => 0x0002,
	get_candelabrum     => 0x0004, candelabrum     => 0x0004,
	get_book            => 0x0008, book            => 0x0008,
	perform_invocation  => 0x0010, invocation      => 0x0010,
	get_amulet          => 0x0020, amulet          => 0x0020,
	entered_planes      => 0x0040, endgame         => 0x0040, planes       => 0x0040,
	entered_astral      => 0x0080, astral          => 0x0080, astral_plane => 0x0080,
	ascended            => 0x0100, ascension       => 0x0100, asc          => 0x0100,
	get_luckstone       => 0x0200, luckstone       => 0x0200,
	finish_sokoban      => 0x0400, sokoban         => 0x0400,
	killed_medusa       => 0x0800, medusa          => 0x0800);


    my $str = shift || "";
    my $nick = shift;
    my $do_count = shift || 0;
    my $no_force_fields = shift || 0;
    my $sql = ""; #"select * from xlogfile";
    my @wheres;

    $str =~ s/^\s+//;
    $str =~ s/\s+$//;

    my @datas = split(" ", $str);

    my $use_like = 0;
    my $nofields = 0;
    my $plrname;
    my $plrname_oper = "=";
    my $tmpd;
    my @sqlsort;

    my $groupby;

    my $skip;

    my $sqllimit = "5";

    my @getfields = ();

    my $errorstr;

    my $has_aggregates = 0;

    foreach $tmpd (@datas) {

	if ($nofields) {
	    $tmpd = $param_subst{lc($tmpd)} if ( grep { $_ eq lc($tmpd) } keys(%param_subst) );
	}

	my ($f, $tmpx, $o, $d) = $tmpd =~ /^([A-Za-z0-9_*]+)(([=><!~:]+)(.+))?$/;

	if (defined $o) {
	    $f = lc($f);
	    $f = $field_renames{$f} if ( grep { $_ eq $f } keys(%field_renames) );

	    if ($o eq "==") { $o = "="; }
	    if ($o eq "~=") { $o = "=~"; }
	    if ($o eq "=:") { $o = ":="; }
	    if ($o eq "!=:") { $o = ":!="; }

 	  if ( grep { $_ eq $o } @operators ) {

	      if ($o eq ":=" || $o eq ":!=") {
		  if (!( grep { $_ eq $f } @fields )) {
		      $errorstr = "unknown field '".$f."'".perhaps_you_meant($f, @fields);
		      next;
		  }
		  $d = lc($d);
		  $d = $field_renames{$d} if ( grep { $_ eq $d } keys(%field_renames) );
		  if (!( grep { $_ eq $d } @fields )) {
		      $errorstr = "unknown field '".$d."'".perhaps_you_meant($d, @fields);
		      next;
		  }
		  next if ($f eq $d);
		  $nofields += 1 if ($f eq "name");
		  if ($o eq ":=") {
		      push(@wheres, $f."=".$d);
		  } elsif ($o eq ":!=") {
		      push(@wheres, $f."!=".$d);
		  }
		  next;
	      }

	    if ( grep { $_ eq $f } @all_param_fields ) {

		if (($f eq "death") && defined $d) {
		    $use_like = 1 if ($d =~ m/\*/);
		    $d =~ s/_/ /g;
		    $d =~ s/\./_/g;
		    $d =~ s/%/_/g;
		    $d =~ s/\*/%/g;
		}

		if ($f eq "conduct") {
		    my $fsel = 0;
		    my @tmpr = split(/[^a-zA-Z_]/, $d);
		    foreach my $tmpz (@tmpr) {
			if ($conduct_names{lc($tmpz)}) {
			    $fsel = $fsel | $conduct_names{lc($tmpz)};
			} else {
			    my $tmpmask = cnv_str_to_bitmask($tmpz, \%conduct_names);
			    if ($tmpmask == -1) {
				$errorstr = "unknown conduct string '".$tmpz."'".perhaps_you_meant($tmpz, keys %conduct_names);
				last;
			    } else {
				$fsel |= $tmpmask;
			    }
			}
		    }
		    if ($o eq "=") {
			push(@wheres, "(".$f." & ".$fsel.")=".$fsel);
		    } elsif ($o eq "!=") {
			push(@wheres, "(".$f." & ".$fsel.")=0");
		    } else {
			$errorstr = "'".$f."' only accepts '=' or '!=' comparison";
		    }
		} elsif ($f eq "deathyear" || $f eq "birthyear") {
		    if ($d =~ m/^\d\d\d\d$/) {
			if ($f eq "deathyear") {
			    push(@wheres, "substr(deathdate,1,4)".$o.$dbh->quote($d)) if ($dbh);
			} else {
			    push(@wheres, "substr(birthdate,1,4)".$o.$dbh->quote($d)) if ($dbh);
			}
		    } else {
			$errorstr = "'".$d."' is not a valid year";
		    }
		} elsif ($f eq "deathmonth" || $f eq "birthmonth") {
		    if (($d =~ m/^\d\d$/) && ($d > 0) && ($d < 13)) {
			if ($f eq "deathmonth") {
			    push(@wheres, "substr(deathdate,5,2)".$o.$dbh->quote($d)) if ($dbh);
			} else {
			    push(@wheres, "substr(birthdate,5,2)".$o.$dbh->quote($d)) if ($dbh);
			}
		    } else {
			$errorstr = "'".$d."' is not a valid month";
		    }
		} elsif ($f eq "deathday" || $f eq "birthday") {
		    if (($d =~ m/^\d\d$/) && ($d > 0) && ($d < 32)) {
			if ($f eq "deathday") {
			    push(@wheres, "substr(deathdate,7,2)".$o.$dbh->quote($d)) if ($dbh);
			} else {
			    push(@wheres, "substr(birthdate,7,2)".$o.$dbh->quote($d)) if ($dbh);
			}
		    } else {
			$errorstr = "'".$d."' is not a valid day of month";
		    }
		} elsif ($f eq "deathdnum") {
		    $d = lc($d);
		    $d = $deathdlev_conv{$d} if ( grep { $_ eq $d } keys(%deathdlev_conv) );
		    if ($d =~ m/^-?\d+/) {
			if ($d < 0) {
			    #push(@wheres, "deathdlev='".$deathdlev_conv{"planes"}."'");
			    push(@wheres, "deathlev".$o."".$dbh->quote($d)."") if ($dbh);
			} else {
			    push(@wheres, $f.$o."".$dbh->quote($d)."") if ($dbh);
			}
		    } else {
			$errorstr = "'".$f."' requires a number or a dungeon name";
		    }
		} elsif ($f eq "deathlev") {
		    $d = lc($d);
		    $d = $deathdlev_conv{$d} if ( grep { $_ eq $d } keys(%deathdlev_conv) );
		    if ($d =~ m/^-?\d+/) {
			if ($d < 0) {
			    #push(@wheres, "deathdlev='".$deathdlev_conv{"planes"}."'");
			    push(@wheres, "deathlev".$o."".$dbh->quote($d)."") if ($dbh);
			} else {
			    push(@wheres, $f.$o."".$dbh->quote($d)."") if ($dbh);
			}
		    } else {
			$errorstr = "'".$f."' requires a level number (or a plane)";
		    }
		} elsif ($f eq "achieve") {
		    my $fsel = 0;
		    my @tmpr = split(/[^a-zA-Z_]/, $d);
		    foreach my $tmpz (@tmpr) {
			if ($achieve_names{lc($tmpz)}) {
			    $fsel = $fsel | $achieve_names{lc($tmpz)};
			} else {
			    my $tmpmask = cnv_str_to_bitmask($tmpz, \%conduct_names);
			    if ($tmpmask == -1) {
				$errorstr = "unknown achievement '".$tmpz."'".perhaps_you_meant($tmpz, keys %achieve_names);
				last;
			    } else {
				$fsel |= $tmpmask;
			    }
			}
		    }
		    if ($o eq "=") {
			push(@wheres, "(".$f." & ".$fsel.")=".$fsel);
		    } elsif ($o eq "!=") {
			push(@wheres, "(".$f." & ".$fsel.")=0");
		    } else {
			$errorstr = "'".$f."' only accepts '=' or '!=' comparison";
		    }
		} elsif ($f eq "skip") {
		    if ($o eq "=") {
			if ($d =~ m/^\d+$/) {
			    $skip = $d;
			} else {
			    $errorstr = "'".$f."' accepts only number as parameter.";
			}
		    } else {
			$errorstr = "'".$f."' accepts only '='.";
		    }
		} elsif ($f eq "limit") {
		    if ($o eq "=") {
			if ($d =~ m/^\d+$/) {
			    $sqllimit = $d;
			    $sqllimit = 10 if ($sqllimit > 10);
			} else {
			    $errorstr = "'".$f."' accepts only number as parameter.";
			}
		    } else {
			$errorstr = "'".$f."' accepts only '='.";
		    }
		} elsif ($f eq "hide") {
		    if ($o eq "=") {
			$d = lc($d);
			$d = $field_renames{$d} if ( grep { $_ eq $d } keys(%field_renames) );
			if ( grep { $_ eq $d } @fields ) {
			    my @tmpgf = ();
			    foreach my $tdg (@getfields) {
				push(@tmpgf, $tdg) if ($tdg ne $d);
			    }
			    @getfields = @tmpgf;
			} else {
			    $errorstr = "cannot hide unknown field '".$d."'".perhaps_you_meant($d, @fields);
			}
		    } else {
			$errorstr = "'".$f."' accepts only '='.";
		    }
		} elsif ($f eq "g" || $f eq "gmax" || $f eq "gmin" || $f eq "group") {

		    if ($groupby) {
			$errorstr = "only one '".$f."' allowed.";
			next;
		    }

		    #if (@sqlsort) {
		    #	$errorstr = "sorting and '".$f."' together not allowed.";
		    #	next;
		    #}

		    if ($o eq "=") {
			$d = lc($d);
			$d = $field_renames{$d} if ( grep { $_ eq $d } keys(%field_renames) );
			if ( grep { $_ eq $d } @fields ) {
			    @getfields = ();
			    push(@getfields, $d);
			    push(@getfields, "count(*)");
			    if ($f eq "gmin") {
				push(@sqlsort, "count(*) asc");
			    } else {
				push(@sqlsort, "count(*) desc");
			    }
			    $groupby = $d;
			    if ($d eq "role") {
				$sqllimit = scalar @nhconst::roles;
			    } else {
				$sqllimit = "10";
			    }
			} else {
			    $errorstr = "cannot group by unknown field '".$d."'".perhaps_you_meant($d, @fields);
			}
		    } else {
			$errorstr = "'".$f."' accepts only '=' as comparison.";
		    }
		} elsif (($f eq "max" || $f eq "min" || $f eq "sort")) {

		    #if ($groupby) {
		    #	$errorstr = "grouping and '".$f."' together not allowed.";
		    #	next;
		    #}

		    if ($o eq "=") {
			$d = lc($d);
			$d = $field_renames{$d} if ( grep { $_ eq $d } keys(%field_renames) );
			if ( grep { $_ eq $d } @fields ) {
			    my $tmps = $d." ";
			    push(@getfields, $d);
			    $tmps .= "desc" if ($f eq "max" || $f eq "sort");
			    $tmps .= "asc" if ($f eq "min");
			    push(@sqlsort, $tmps);
			    $sqllimit = "10";
			} else {
			    $errorstr = "cannot sort by unknown field '".$d."'".perhaps_you_meant($d, @fields);
			}
		    } else {
			$errorstr = "'".$f."' accepts only '=' as comparison.";
		    }
		} elsif ($o eq "=~") {
		    my @fsel;
		    my @tmpr = split("\\|", $d);
		    foreach my $tmpz (@tmpr) {
			push(@fsel, $f." LIKE ".$dbh->quote($tmpz)."") if ($dbh);
		    }
		    $nofields += 1 if ($f eq "name");
		    push(@wheres, "(".join(" or ", @fsel).")");
		} else {

		    $o = " LIKE " if (($f eq "death") && (($o eq "=")));
		    if ($use_like == 1) {
			$o = " NOT LIKE " if (($o eq "<>") || ($o eq "!="));
			$use_like = 0;
		    }

		    if (($f eq "role") || ($f eq "race") ||
			($f eq "gender") || ($f eq "align") ||
			($f eq "gender0") || ($f eq "align0")) {
			$d = substr(ucfirst(lc($d)),0,3);
		    } elsif (($f eq "birthdate") || ($f eq "deathdate")) {
			$d = lc($d);
			my %tmpdate = str_to_yyyymmdd($d);
			if ($tmpdate{'error'}) {
			    $errorstr = "'".$f."': ".$tmpdate{'error'};
			} else {
			    $d = $tmpdate{'date'};
			}
		    } elsif (($f eq "starttime") || ($f eq "endtime")) {
			$d = lc($d);
			my %tmpts = str_to_timestamp($d);
			if ($tmpts{'error'}) {
			    $errorstr = "'".$f."': ".$tmpts{'error'};
			} else {
			    $d = $tmpts{'timestamp'};
			}
		    } elsif ($f eq "realtime") {
			$d = conv_hms($d);
		    }

		    $nofields += 1 if ($f eq "name");
		    push(@wheres, $f.$o."".$dbh->quote($d)."") if ($dbh);
		}
	    } else {
		my @all_unknown_fields = (@all_param_fields, keys(%field_renames));
		$errorstr = "unknown field '".$f."'".perhaps_you_meant($f, @all_unknown_fields);
	    }
	  } else {
	      $errorstr = "unknown operator '".$o."'";
	  }
	} else { # just a simple string param, not foo=bar
	    $f = $tmpd;
	    $nofields = $nofields + 1;
	    if ($nofields != 1) { # we've already found a player name, maybe it's something else
		$f = lc($f);
		$f = $field_renames{$f} if ( grep { $_ eq $f } keys(%field_renames) );
		if ( grep { $_ eq $f } @fields ) {
		    push(@getfields, $f);
		} else {
		    my $tmpd = ucfirst(lc($f));
		    my $tmp_oper = "=";
		    my %aggr = is_aggregate_func($f);
		    if (substr($tmpd,0,1) eq "!") {
			$tmp_oper = "!=";
			$tmpd = ucfirst(substr($tmpd, 1));
		    }
		    if ( grep { $_ eq $tmpd } @nhconst::roles ) {
			push(@wheres, "role".$tmp_oper.$dbh->quote($tmpd)) if ($dbh);
		    } elsif ( grep { $_ eq $tmpd } @nhconst::races ) {
			push(@wheres, "race".$tmp_oper.$dbh->quote($tmpd)) if ($dbh);
		    } elsif ( grep { $_ eq $tmpd } @nhconst::aligns ) {
			push(@wheres, "align".$tmp_oper.$dbh->quote($tmpd)) if ($dbh);
		    } elsif ( grep { $_ eq $tmpd } @nhconst::genders ) {
			push(@wheres, "gender".$tmp_oper.$dbh->quote($tmpd)) if ($dbh);
		    } elsif ($aggr{aggregate}) {
			my $tmpf = $aggr{field};
			$tmpf = $field_renames{$tmpf} if ( grep { $_ eq $tmpf } keys(%field_renames) );
			if ( grep { $_ eq $tmpf } @fields ) {
			    push(@getfields, $aggr{aggregate}."(".$tmpf.")");
			    $has_aggregates = 1;
			} else {
			    $errorstr = "unknown field '".$tmpf."'".perhaps_you_meant($tmpf, @fields);
			}
		    } elsif ($simple_settings{$f}) {
			$simple_settings{$f} = 1;
		    } else {
			$errorstr = "unknown field '".$f."'".perhaps_you_meant($f, @fields);
		    }
		}
	    } else { # assume it's a player name

		if (substr($f,0,1) eq "!") {
		    $plrname_oper = "!=";
		    $f = substr($f, 1);
		}

		if ($f eq "*") {
		    $errorstr = "cannot negate name '*'" if ($plrname_oper eq "!=");
		    # nothing
		} elsif (($f eq ".") && defined($nick)) {
		    $plrname = $nick;
		} else {
		    if ($f =~ m/^[a-zA-Z0-9]+$/) {
			$plrname = $f;
		    } else {
			$errorstr = "illegal player name '".$f."'" ;
		    }
		}
	    }
	}
    }

    if ($nofields >= 1) {
	push(@wheres, "lower(name)".$plrname_oper.$dbh->quote(lc($plrname))) if ($plrname && $dbh);
    }

    if (!@sqlsort && ($has_aggregates == 0)) {
	@sqlsort = ("points desc");
	push(@getfields, "points");
    }

    if (@getfields) {
        my %seen;
        my @uniqed = grep !$seen{$_}++, @getfields;
        @getfields = @uniqed;
    }

    if ($has_aggregates == 0) {
	if ($no_force_fields) {
	    push(@getfields, "points") if ((scalar(@getfields) < 1) && !$groupby);
	} else {
	    push(@getfields, "name") if (!$groupby);
	    push(@getfields, "points") if ((scalar(@getfields) < 2) && !$groupby);
	}
	my %seen;
	my @uniqed = grep !$seen{$_}++, @getfields;
	@getfields = @uniqed;
    }

    if ($do_count == 1) {
	@getfields = ("count(1)");
	undef($sqllimit);
	undef(@sqlsort);
	undef($skip);
    }

    $sql .= "select ";
    $sql .= "distinct " if ($simple_settings{distinct});
    $sql .= join(",", @getfields)." from xlogfile";

    $sql .= " where ".join(" and ", @wheres) if (@wheres);

    $sql .= " group by ".$groupby if ($groupby);

    $sql .= " order by ".join(",",@sqlsort) if (@sqlsort);

    $sql .= " limit ".$sqllimit if ($sqllimit);

    $sql .= " offset ".$skip if ($skip);

    if ($do_count == 1) {
	$sql = "select count(1) from (".$sql.") as tempdb" if ($groupby);
    }

    my %ret = (sql => $sql, fields => join(",",@getfields));
    if ($errorstr) {
	$ret{"error"} = $errorstr;
	delete $ret{"sql"};
    }

    $ret{"plrname"} = "name".$plrname_oper.$plrname if ($plrname);

    $ret{"offset"} = $skip if ($skip);

    return %ret;
}


sub is_valid_playername {
    my $s = shift;
    return 1 if ($s =~ m/^[0-9a-zA-Z]+$/);
    return 0;
}

sub paramstr_is_used_playername {
    my $plrname = shift || "";
    my $name = "";
    return 0 if (!is_valid_playername($plrname));

    my $dbh = DBI->connect("dbi:".$dgldb->{'dbtype'}.":dbname=".$dgldb->{'db'},"","",{AutoCommit => 1, PrintError => 1});
    return 0 if (!$dbh);

    my $sth = $dbh->prepare("SELECT username FROM dglusers WHERE username like ".$dbh->quote($plrname));
    if ($dbh->err()) { debugprint("$DBI::errstr"); return 0; }
    $sth->execute();

    my $rowcnt = $sth->fetchrow_hashref();
    return 0 if (!$rowcnt->{'username'});

    return 1;
}

sub paramstr_playername {
    my $plrname = shift || "";
    my $name = "";
    return "" if (!is_valid_playername($plrname));

    my $dbh = DBI->connect("dbi:".$dgldb->{'dbtype'}.":dbname=".$dgldb->{'db'},"","",{AutoCommit => 1, PrintError => 1});
    return "" if (!$dbh);

    my $sth = $dbh->prepare("SELECT username FROM dglusers WHERE username like ".$dbh->quote($plrname));
    if ($dbh->err()) { debugprint("$DBI::errstr"); return ""; }
    $sth->execute();

    my $rowcnt = $sth->fetchrow_hashref();
    return $rowcnt->{'username'} if ($rowcnt->{'username'});
    return "";
}

sub paramstr_iswikipage {
    my $str = shift || "";
    if (length($str) > 0) {
        my $db = DBI->connect("dbi:".$nethackwikidb->{dbtype}.":".$nethackwikidb->{db}.":localhost",
                              $nethackwikidb->{user}, $nethackwikidb->{pass},
                              {AutoCommit => 1, PrintError => 1});
        if ($db->err()) { debugprint("$DBI::errstr"); return ""; }
        if ($db) {
            $str =~ tr/ /_/;
            my $sth = $db->prepare("SELECT count(1) AS numpages FROM page WHERE LOWER(CONVERT(page_title USING latin1)) LIKE ".$db->quote(lc($str))." AND page_namespace=0");
            $sth->execute();
            my $rowcnt = $sth->fetchrow_hashref();
            return 0 if ($rowcnt->{'numpages'} != 1);
            return 1;
        }
    }
    return 0;
}

sub paramstr_wikipage {
    my $str = shift || "";
    if (length($str) > 0) {
        my $db = DBI->connect("dbi:".$nethackwikidb->{dbtype}.":".$nethackwikidb->{db}.":localhost",
                              $nethackwikidb->{user}, $nethackwikidb->{pass},
                              {AutoCommit => 1, PrintError => 1});
        if ($db->err()) { debugprint("$DBI::errstr"); return ""; }
        if ($db) {
            $str =~ tr/ /_/;
            my $sth = $db->prepare("SELECT page_title, count(1) as numpages FROM page WHERE LOWER(CONVERT(page_title USING latin1)) LIKE ".$db->quote(lc($str))." AND page_namespace=0");
            $sth->execute();
            my $rowcnt = $sth->fetchrow_hashref();
            return $rowcnt->{'page_title'} if ($rowcnt->{'page_title'} && ($rowcnt->{'numpages'} == 1));
        }
    }
    return "";
}

sub paramstr_nwikipages {
    my $str = shift || "";
    if (length($str) > 0) {
        my $db = DBI->connect("dbi:".$nethackwikidb->{dbtype}.":".$nethackwikidb->{db}.":localhost",
                              $nethackwikidb->{user}, $nethackwikidb->{pass},
                              {AutoCommit => 1, PrintError => 1});
        if ($db->err()) { debugprint("$DBI::errstr"); return ""; }
        if ($db) {
            $str =~ tr/ /_/;
            my $sth = $db->prepare("SELECT count(1) AS numpages FROM page WHERE LOWER(CONVERT(page_title USING latin1)) LIKE ".$db->quote(lc($str))." AND page_namespace=0");
            $sth->execute();
            my $rowcnt = $sth->fetchrow_hashref();
            return $rowcnt->{'numpages'} if ($rowcnt->{'numpages'});
        }
    }
    return 0;
}

sub buglist_update {
    my ( $self ) = $_[ OBJECT ];

    my $outstr = $buglist_db->update_buglist();
    if ($outstr) {
	$self->botspeak($outstr);
    }

    debugprint("buglist_update") if ($self->{'Debug'});

    if ($kernel) { $kernel->delay('buglist_update' => 300); }
}



# returns an array containing the active players, sorted alphabetically
sub player_list {
    my $self = shift;
    my $fmask = shift || "";
    my @return;
    my @files;

    $fmask = '^.*'.$fmask.'.*:\d+-\d+-\d+\.\d+:\d+:\d+\.ttyrec$';

    @files = find_files($self->{'dglInprogPath'}, $fmask);

    if ($#files >= 0) {
	my $c;
	my $count = 0;

	my @tmpf = sort { lc $a cmp lc $b } @files;

	foreach (@tmpf) {
	    my ($b) = /^([^:]*).*/;
	    push @return, $b;
	}
    }

    return @return;
}

sub whereis_players {
    my $self = shift;
    my $plr = lc(shift) || undef;
    my $order = lc(shift) || "name";
    my @players = $self->player_list();
    my @return;
    my $pretext = "";

    my @data;

    $plr = paramstr_trim($plr);

    undef $plr if ((defined $plr) && !($plr =~ m/^[a-z0-9]+$/));

    $pretext = "$#players player" . (($#players == 1) ? '' : 's') . ': ' if (!$plr);

#depth=29:dnum=0:hp=134:maxhp=134:turns=46326:score=343234:role=Caveman:race=human:gender=Mal:align=lawful:conduct=0xf88:amulet=0

    foreach (@players) {
	next if ((defined $plr) && !(lc($_) eq $plr));
	my $whereisfile = $self->{'WhereIsDir'}.$_.'.whereis';
	open(WHEREISFILE, $whereisfile) || next;
	my @whereisdata = <WHEREISFILE>;
	close(WHEREISFILE);

	my $whisd = {parse_xlogline($whereisdata[0], 1)};

	$whisd->{'name'} = $_;
	$whisd->{'role'} = substr($whisd->{'role'},0,3);
	$whisd->{'race'} = ucfirst(substr($whisd->{'race'},0,3));
	$whisd->{'race'} =~ s/^Elv$/Elf/;
	$whisd->{'align'} = ucfirst(substr($whisd->{'align'},0,3));

	$whisd->{'depth'} = int($whisd->{'depth'});
	$whisd->{'dnum'} = int($whisd->{'dnum'});
	$whisd->{'hp'} = int($whisd->{'hp'});
	$whisd->{'maxhp'} = int($whisd->{'maxhp'});
	$whisd->{'turns'} = int($whisd->{'turns'});
	$whisd->{'score'} = int($whisd->{'score'});
	$whisd->{'amulet'} = int($whisd->{'amulet'});

	$whisd->{'dungeon'} = $nhconst::dnums{$whisd->{'dnum'}};
	$whisd->{'sdungeon'} = $nhconst::dnums_short{$whisd->{'dnum'}};

	$whisd->{'depthname'} = (($whisd->{'depth'} < 0) ? $nhconst::dnums{$whisd->{'depth'}} : $whisd->{'depth'});

	push @data, $whisd;

    }

    return "" if (scalar(@data) < 1);

    $order =~ s/^--?// if (defined($order));

    $order = "name" if (!defined($order) || !defined($data[0]->{$order}));

    my $order2 = "name";
    $order2 = "depth" if ($order eq "dnum");
    $order2 = "dnum" if ($order eq "depth");

    $order2 = "name" if ($order2 eq $order);
    $order2 = "turns" if ($order2 eq $order);

    my @sorted = sort { $a->{'amulet'} <=> $b->{'amulet'} || $a->{$order} cmp $b->{$order} || $a->{$order2} cmp $b->{$order2} } @data;

    my $prevk;

    foreach (@sorted) {

	my $whisd = $_;

	if (defined($plr)) {
	    my $str = $whisd->{'name'}.' ('.$whisd->{'role'}.' '.$whisd->{'race'}.' '.$whisd->{'gender'}.' '.$whisd->{'align'}.')';
	    $str .= ', '.$whisd->{'score'}.' points';
	    $str .= ', '.$whisd->{'dungeon'}.'@'.$whisd->{'depthname'};
	    $str .= ', T:'.$whisd->{'turns'};
	    $str .= ', HP:'.$whisd->{'hp'}.'('.$whisd->{'maxhp'}.')' if ($whisd->{'hp'} < ($whisd->{'maxhp'} / 5));
	    $str .= ', with Amulet' if ($whisd->{'amulet'});

	    push @return, $str;
	} else {
	    my $str;
	    $str .= $whisd->{'name'};
	    $str .= '[Amulet]' if ($whisd->{'amulet'});
	    $str .= '('.$whisd->{'sdungeon'}.'@'.$whisd->{'depthname'}.')';

	    $str .= '[HP:'.$whisd->{'hp'}.'/'.$whisd->{'maxhp'}.']' if ($order eq "hp" || $order eq "maxhp");
	    $str .= '[T:'.$whisd->{'turns'}.']' if ($order eq "turns");
	    $str .= '[S:'.$whisd->{'score'}.']' if ($order eq "score");


	    push @return, $str;
	}
    }
    return $pretext.join(', ', @return);
}

# current players
sub current_players {
    my $self = shift;
    my @players = $self->player_list();
    my @return;
    my $pretext;

    my $plrnames = join(', ', @players);
    $pretext = scalar(@players) . " player" . 
        ((scalar(@players) == 1) ? '' : 's') . ': ';

    if (@players) {
	$plrnames = $pretext.$plrnames;
	push @return, $plrnames;
    } else {
	push @return, "No players.";
    }

    return @return;
}

#### logfile stuff

# get_log_data("nick")
sub log_data {
    my $self = shift;
    my $nick = shift;
    my $retstr;

    my $first = undef;
    my $last = undef;
    my $games = 0;
    my $ascended = 0;
    my $score = 0;
    my $deaths = 0;
    my $quits = 0;
    my $escapes = 0;
    my $dbdata;

    $nick =~ tr/A-Z/a-z/;

    db_connect($self);
    return "Xlogfile db disabled." if (!$dbh);
    my $sth = $dbh->prepare("SELECT name,birthdate,deathdate,death,points,deaths FROM xlogfile WHERE "
	."name like ".$dbh->quote($nick));
    $sth->execute();

    while ($dbdata = $sth->fetchrow_hashref()) {
	    $first = $dbdata->{birthdate} if (!(defined $first));
	    $last = $dbdata->{deathdate};
	    $games++;

	    $ascended++ if ($dbdata->{death} =~ /^ascended$/);
	    $quits++ if ($dbdata->{death} =~ /^quit/);
	    $escapes++ if ($dbdata->{death} =~ /^escaped/);
	    $score = $dbdata->{points} if ($dbdata->{points} > $score);
	    $deaths += $dbdata->{deaths};
    }
    db_disconnect();

    if ($games > 0) {
	my $ret = "$nick has played $games game".($games == 1 ? "" : "s");

	if ($first != $last) {
	    $ret = $ret . ", between $first and $last";
	} else {
	    $ret = $ret . ", on $first";
	}
	$ret = $ret . ", highest score $score";

	$ret = $ret . ", ascended $ascended" if ($ascended > 0);
	if ($deaths > 0) {
	    my $lifesaved = ($deaths + $quits + $escapes + $ascended - $games);
	    $deaths = ($deaths - $lifesaved) if ($lifesaved > 0);
	    $ret = $ret . ", died $deaths" if ($deaths > 0);
	    $ret = $ret . ", lifesaved $lifesaved" if ($lifesaved > 0);
	}
	$ret = $ret . ", quit $quits" if ($quits > 0);
	$ret = $ret . ", escaped $escapes" if ($escapes > 0);
	$ret = $ret . " time".(($deaths+$escapes+$quits+$ascended) == 1 ? "" : "s");

	$retstr = $ret;
    } else {
	$retstr = "No games for $nick.";
    }

    return $retstr;
}

# get_asc_data("nick")
sub asc_data {
    my $self = shift;
    my $nick = shift;
    my $retstr;

    my $games = 0;
    my $ascended = 0;
    my %roles = ();
    my %races = ();
    my %genders = ();
    my %aligns = ();
    my $dbdata;

    $nick =~ tr/A-Z/a-z/;

    db_connect($self);
    return "Xlogfile db disabled." if (!$dbh);
    my $sth = $dbh->prepare("SELECT name,death,role,race,gender,align FROM xlogfile WHERE "
	."name like ".$dbh->quote($nick));
    $sth->execute();

    while ($dbdata = $sth->fetchrow_hashref()) {
	$games++;
	if ($dbdata->{death} =~ /^ascended$/) {
	    $ascended++;
	    $roles{$dbdata->{role}}++;
	    $races{$dbdata->{race}}++;
	    $genders{$dbdata->{gender}}++;
	    $aligns{$dbdata->{align}}++;
	}
    }
    db_disconnect();

    if ($ascended) {
        my $ret = sprintf('%s has ascended %d time%s in %d game%s (%.2f%%): ', $nick, $ascended, ($ascended == 1 ? '' : 's'), $games, ($games == 1 ? '' : 's'), 100*$ascended/$games);

	my ($role, $race, $gender, $align, $count);

	$count = 0;
	foreach $role (sort {$roles{$b} <=> $roles{$a} || $a cmp $b} keys %roles) {
	    $ret .= ' ' if $count++;
	    $ret .= $roles{$role} . 'x' . $role;
	}

	$ret .= ',  '; $count = 0;
	foreach $race (sort {$races{$b} <=> $races{$a} || $a cmp $b} keys %races) {
	    $ret .= ' ' if $count++;
	    $ret .= $races{$race} . 'x' . $race;
	}

	$ret .= ',  '; $count = 0;
	foreach $gender (sort {$genders{$b} <=> $genders{$a} || $a cmp $b} keys %genders) {
	    $ret .= ' ' if $count++;
	    $ret .= $genders{$gender} . 'x' . $gender;
	}
	$ret .= ',  '; $count = 0;

	foreach $align (sort {$aligns{$b} <=> $aligns{$a} || $a cmp $b} keys %aligns) {
	    $ret .= ' ' if $count++;
	    $ret .= $aligns{$align} . 'x' . $align;
	}

	$retstr = $ret;
    }
    elsif ($games) {
	$retstr = sprintf('%s has not ascended in %d game%s.', $nick, $games, $games == 1 ? '' : 's');
    }
    else {
	$retstr = "No games for $nick.";
    }

    return $retstr;
}

# tail events

my $curpos;
my $last_played_game;

my $livelog_pos;

my $LOGFILE;
my $LIVELOGFILE;

sub setup_tail {
    my $self = shift;
    my $fname = $self->{'nh_logfile'};
    my $livefname = $self->{'nh_livelogfile'};
    debugprint("setup_tail");
    if (open($LOGFILE,$fname)) {
	seek($LOGFILE,0,2);
	$curpos = tell($LOGFILE);
    } else {
	debugprint("Can't open file $fname, logfile checking disabled.");
	$self->{'CheckLog'} = 0;
    }

    if (open($LIVELOGFILE,$livefname)) {
	seek($LIVELOGFILE,0,2);
	$livelog_pos = tell($LIVELOGFILE);
    } else {
	debugprint("Can't open file $livefname, livelog checking disabled.");
	$self->{'CheckLog'} = 0;
    }
}

sub on_d_tick {
	my ( $self ) = $_[ OBJECT ];
	my $line;

	for ($curpos = tell($LOGFILE); $line = <$LOGFILE> ; $curpos = tell($LOGFILE)) {
		my $recordno = 0;
		my $counter = 0;

		if (!$line) { next; }

		$line =~ s/\n//;

		my %dat = parse_xlogline($line);

		if (($dat{'points'} < 1000) && ($dat{'death'} =~ /^quit|^escaped/)) { next; }
		# someone thought of spamming
#		elsif ($death =~ /((http)|(www\.)|(ipod)|(tinyurl)|(xrl)/i)) { next; }

		my $infostr = "$dat{'name'} ($dat{'crga'}), $dat{'points'} points, $dat{'death'}";
		my $oldstyle = xlog2record($line);
		my $recordmatch;
		my $twitinfo = $infostr;

		$self->botspeak($infostr);
		$last_played_game = $oldstyle;

		open(RECORDFILE, $self->{'NHRecordFile'}) || die ("Can't open file");
		while (<RECORDFILE>) {
			$counter++;
			$recordmatch = $_;
			$recordmatch =~ s/\n$//;
			if ($recordmatch eq $oldstyle) { $recordno = $counter; }
		}
		if ($recordno) {
			$self->botspeak("$dat{'name'} reaches #$recordno on the top 2000 list.");
		}
		close(RECORDFILE);

		if ($dat{'death'} =~ /^ascended$/) {

		    my $dumpfile = fixstring($self->{'nh_dumppath'}, %dat);
		    if (-e "$dumpfile") {
			my $url = fixstring($self->{'nh_dumpurl'}, %dat);
			$self->botspeak($url);
			$twitinfo = "$dat{'name'} $dat{'death'}: $url";
		    }

		    #if (($self->{'use_twitter'} == 1) && (-e "/usr/bin/curl")) {
		    #	`/usr/bin/curl --max-time 3 -u "$self->{'twitteruserpass_asc'}" -d status="$twitinfo" http://twitter.com/statuses/update.xml`;
		    #}

		}
		#if (($self->{'use_twitter'} == 1) && (-e "/usr/bin/curl")) {
		#    `/usr/bin/curl --max-time 3 -u "$self->{'twitteruserpass'}" -d status="$twitinfo" http://twitter.com/statuses/update.xml`;
		#}
	}
	seek($LOGFILE,$curpos,0);


	for ($livelog_pos = tell($LIVELOGFILE); $line = <$LIVELOGFILE> ; $livelog_pos = tell($LIVELOGFILE)) {
		if (!$line) { next; }
		$line =~ s/\n//;
		if ($line =~ m/^.+$/) {
		    my %dat = parse_xlogline($line);
		    my $infostr = "$dat{'player'} ($dat{'crga'}) $dat{'message'}, on turn $dat{'turns'}";
		    $self->botspeak($infostr);
		}
	}
	seek($LIVELOGFILE,$livelog_pos,0);


	$kernel->delay('d_tick' => 3);
}

sub userdata_name {
    my $self = shift;
    my $name = shift;

    $name =~ tr[a-zA-Z0-9][]cd;

    my $directory = $self->{'userdata_name'}.lc(substr($name,0,1))."/";
    my ($xname) = find_files($directory, qr/^\Q$name\E$/i);
    if (!$xname) {
	$directory = $self->{'userdata_name'}.uc(substr($name,0,1))."/";
	return undef unless ($xname) = find_files($directory, qr/^\Q$name\E$/i);
    }
    return $xname;
}

sub dumplog_url {
    my $self = shift;
    my $name = $self->userdata_name(shift)
        or return;

    my $directory = $self->{'userdata_name'};
    my $userdir = "$directory/".substr($name, 0,1)."/$name/dumplog/";

    opendir DIR, $userdir;
    my @files = sort grep {/^\d+\.nh343\.txt$/} readdir DIR;

    if (@files) {
	my %namehash = (name=>$name);
        return fixstring($self->{'userdata_dumpname_puburl'}, %namehash)."$files[-1]";
    }

    return undef;
}

#### highscores

sub highscore_query_nick {
    my $self = shift;
    my $player = shift;
    my @return;
    my $counter = 0;
    my $line;
    my $num;

    if ($player =~ /^\s*#(\d+)\s*$/) { # "!hsn #2000"
	$num = $1;
	if ($num > 2000) {
	    push @return, "The high score table only has 2000 entries.";
	    return @return;
	}
    }

    open(RECORDFILE, $self->{'NHRecordFile'}) || die ("Can't open file");
    while (<RECORDFILE>) {
 	$counter++;
	$line = $_;
 	my ($name) = $line =~
 	    /^3.\d.\d+ [\d\-]+ [\d\-]+ [\d\-]+ [\d\-]+ [\d\-]+ \d+ [\d ]+ [A-Z][a-z]+ [A-Z][a-z]+ [MF][a-z]+ [A-Z][a-z]+ ([^,]+),.*$/;
	# the structure of the following code tries to eliminate unnecessary checks and rechecks
	if (defined($num)) {
	    if ($counter == $num) {
 	        push(@return, ($counter.".  ".demunge_recordline($line, 9)));
 	        close(RECORDFILE);
 	        return @return;
	    }
	} else {
	    $name =~ tr/A-Z/a-z/;
	    if ($name =~ m/\Q$player\E/) {
		push(@return, ($counter.".  ".demunge_recordline($line, 9)));
		close(RECORDFILE);
		return @return;
	    }
	}
    }
    close(RECORDFILE);

    if (!@return) # no high score for $player
    {
	db_connect($self);
	return ("Xlogfile db disabled.") if (!$dbh);
	my $sth = $dbh->prepare("SELECT max(points) FROM xlogfile WHERE name=".$dbh->quote($player));
	$sth->execute();
	my ($high) = $sth->fetchrow_array();
	db_disconnect();

      if (!defined $high)
      {
        push @return, "No games for $player.";
      }
      else
      {
        push @return, "Player $player is not on the high score list, but has a high score of $high points.";
      }
    }
    return @return;
}

sub database_sync {
    my ($self) = $_[ OBJECT ];
    $learn_db->sync();
    if ($kernel) { $kernel->delay('database_sync' => 600); }
}

################################################# OTHER BOT STUFF

# id of dcc chat session to show notices/msgs to
my $send_msg_id = undef;

sub bot_priv_msg {
    my ( $self, $msg ) = @_;
    if (defined $send_msg_id) {
	$self->botspeak("BOTPRIVMSG: $msg", $send_msg_id);
    }
}


# Handle connect event
# Join specified channels
sub on_connect {

    my ( $self ) = $_[ OBJECT ];
#    $irc->yield( 'mode', $self->{'Nick'}, '+B' );

    debugprint("on_connect");

    sleep 2;

    $self->botspeak("identify $self->{'Nickpass'}", 'Nickserv');

    debugprint("nickserv");

    sleep 5; # just wait a bit for nickserv to cloak us

    foreach my $chan ( @{ $self->{'Channels'} } ) {
        $irc->yield('join', $chan);
    }
    debugprint("join channels");
#    $kernel->delay('keepalive' => 300);
}

# Someone pinged us, handle it.
sub on_ping {

    my ( $self, $who ) = @_[ OBJECT, ARG0 ];
    my $nick = ( split /!/, $who )[0];
    $irc->yield('ctcpreply', $nick, "PING", "PONG");
    $self->bot_priv_msg("PING from $nick");
}

# Someone changed their nick, handle it.
sub on_nick {
    my ( $self, $who, $nnick ) = @_[ OBJECT, ARG0, ARG1 ];
    my $nick = ( split /!/, $who )[0];
    $nick =~ tr/A-Z/a-z/;
    $seen_db->seen_log($nick, "changed nick to $nnick");
    if ((defined $send_msg_id) && ($nick eq $send_msg_id)) { $send_msg_id = $nnick; }
    $nnick =~ tr/A-Z/a-z/;
    $seen_db->seen_log($nnick, "changed nick from $nick");
}

# Handle CTCP Version
sub on_ver {

    my ( $self, $who ) = @_[ OBJECT, ARG0 ];
    my $nick = ( split /!/, $who )[0];
    $irc->yield('ctcpreply', $nick, "VERSION", "Oh no, $self->{'Nick'}'s using the touch of death!");
    $self->bot_priv_msg("CTCP VERSION from $nick");
}

# Handle CTCP Finger
sub on_finger {

    my ( $self, $who ) = @_[ OBJECT, ARG0 ];
    my $nick = ( split /!/, $who )[0];
    $irc->yield('ctcpreply', $nick, "FINGER", "Oh no, $self->{'Nick'}'s using the touch of death!");
    $self->bot_priv_msg("CTCP FINGER from $nick");
}

# Handle CTCP Page
sub on_page {

    my ( $self, $who ) = @_[ OBJECT, ARG0 ];
    my $nick = ( split /!/, $who )[0];
    $irc->yield('ctcpreply', $nick, "PAGE", "Oh no, $self->{'Nick'}'s using the touch of death!");
    $self->bot_priv_msg("CTCP PAGE from $nick");
}

# Handle CTCP Time
sub on_time {

    my ( $self, $who ) = @_[ OBJECT, ARG0 ];
    my $nick = ( split /!/, $who )[0];
    my $ts = scalar(localtime);
    $irc->yield('ctcpreply', $nick, "TIME", $ts );
    $self->bot_priv_msg("CTCP TIME from $nick");
}

sub mangle_msg_for_trigger {
    my $self = shift;
    my $msg = shift || "";
    $msg =~ s/\s+/ /g;
    $msg =~ s/[!,\.]+$//;
    $msg = paramstr_trim(lc($msg));
    $msg =~ s/\b\L$self->{'Nick'}\E\b/\$self/g;
    $msg =~ tr/ /_/;
    return $msg;
}

# Log actions
sub on_action {
    my ( $self, $who, $where, $msg ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];

    my $nick = ( split /!/, $who )[0];
    my $channel = $where->[0];
    debugprint("[$channel] Action: *$nick $msg");

    $self->log_channel_msg($channel, $nick, "*$nick ".$msg);

    $seen_db->seen_log($nick, "acted out \"$nick $msg\"");

    $msg = $self->mangle_msg_for_trigger($msg);
# eg. "paxed kicks Rodney" -> "$act_kicks_$self"

    $self->handle_learndb_trigger($channel, $nick, '$act_'.$msg);
}

# Handle mode changes
sub on_mode {
    my ( $self, $who, $where, $mode, $nicks ) = @_[ OBJECT, ARG0, ARG1, ARG2, ARG3 ];

    my $nick = ( split /!/, $who )[0];
    $self->{'Nick'} eq $where
      ? debugprint("[$where] MODE: $mode")
      : debugprint("[$where] MODE: $mode $nicks by: $nick");
}

# Handle notices
sub on_notice {
    my ( $self, $who, $msg ) = @_[ OBJECT, ARG0, ARG2 ];

    my $nick = ( split /!/, $who )[0];
    debugprint("[$self->{'Nick'}] NOTICE: $nick: $msg");

    $self->bot_priv_msg("NOTICE: <$nick> $msg");
}

# Handle kicks
sub on_kick {
    my ( $self, $who, $chan, $kickee, $msg ) = @_[ OBJECT, ARG0, ARG1, ARG2, ARG3 ];

    my $nick = ( split /!/, $who )[0];
    debugprint("[$chan] KICK: $nick: $kickee ($msg)");
    $nick =~ tr/A-Z/a-z/;
    $seen_db->seen_log($nick, "kicked by $kickee ($msg)");
}

# Handle someone quitting.
sub on_quit {
    my ( $self, $who, $msg ) = @_[ OBJECT, ARG0, ARG1 ];

    my $nick = ( split /!/, $who )[0];
    debugprint("[$self->{'Nick'}] QUIT: $nick: $msg");
    $nick =~ tr/A-Z/a-z/;
    if ((defined $send_msg_id) && ($nick eq $send_msg_id)) { undef $send_msg_id; }
    $seen_db->seen_log($nick, "quit ($msg)");
}

# Handle join event
sub on_join {
    my ( $self, $who, $where ) = @_[ OBJECT, ARG0, ARG1 ];

    my $irc = $_[SENDER]->get_heap();

    my $nick = ( split /!/, $who )[0];
    debugprint("[$where] JOIN: $nick");

    if ($nick eq $irc->nick_name()) {
	push(@{$self->{'joined_channels'}}, $where);
	$self->botspeak("So thou thought thou couldst kill me, fool.", $where);
    }

    $nick =~ tr/A-Z/a-z/;
    $seen_db->seen_log($nick, "joined $where");
}

# Handle part event
sub on_part {
    my ( $self, $who, $where ) = @_[ OBJECT, ARG0, ARG1 ];

    debugprint("on_part");

    my $nick = ( split /!/, $who )[0];
    debugprint("[$where] PART: $nick");
    $nick =~ tr/A-Z/a-z/;
    if ((defined $send_msg_id) && ($nick eq $send_msg_id)) { undef $send_msg_id; }
    $seen_db->seen_log($nick, "parted $where");
}

# Changes nick if current nick is taken
sub on_nick_taken {
    my ( $self ) = $_[ OBJECT ];

    debugprint("on_nick_taken");

    my $nick  = $self->{'AltNick'};
    $irc->yield('nick', "$nick");
    debugprint("Nick was taken, trying $nick");
    # TODO: ghost $self->{'Nick'} and change nick to that.
}

# find the channel where we should do the action in.
# $channel = $self->channel_for_action('i_say_foo');
# $self->botspeak("foo", $channel);
sub channel_for_action {
    my ( $self, $action ) = @_;

    my $chan = $self->{'actions'}{$action}{'channel'} || undef;
    return $chan if (defined $chan);
    return @{$self->{'Channels'}}[0];
}

# Communicate with channel/nick
sub botspeak {
    my ($self, $msg, $channel, $donotice) = @_;

    my $capab_msg_maxlen = 400; # TODO: get this from the CAPAB string.

    my @lines = split("\n", $msg);

    if (defined $channel && ($channel =~ m/^#/)) {
	if (!( grep {$_ eq $channel } @{$self->{'joined_channels'}} )) {
	    $irc->yield('join', $channel);
	}
    }

    foreach my $tmpline (@lines) {
	my @msglines = splitline($tmpline, $capab_msg_maxlen);
	foreach $msg (@msglines) {
	    $irc->yield((((defined $donotice) && ($donotice == 1)) ? 'notice' : 'privmsg'),
			  ((defined $channel) ? $channel : @{$self->{'Channels'}}[0]),
			  $msg);

	    if (defined $channel && ($channel =~ m/^#/)) {
		$self->log_channel_msg($channel, $self->{'Nick'}, $msg);
	    }

	}
    }
}

sub botaction {
    my ($self, $msg, $channel) = @_;
    $irc->yield('sl', "PRIVMSG $channel :\001ACTION $msg\001");
    if (defined $channel && ($channel =~ m/^#/)) {
	$self->log_channel_msg($channel, $self->{'Nick'}, "*".$self->{'Nick'}." ".$msg);
    }
}

# Borrowed this code from another bot
# Can't for the life of me remember which one
# Please, let me know if it was you, so I can
# give props!!
sub keepalive {
    my ( $self, $heap ) = @_[ OBJECT, HEAP ];

#    debugprint("keepalive");

#    $heap->{'keepalive_time'} += 30;
    $kernel->delay('keepalive' => 300);
#    $self->botspeak(@{$self->{'Channels'}}[0], "KEEPALIVE: time:$heap->{'keepalive_time'}");
    $irc->yield('sl', 'PING '.time());
}


######## pub command repeating prevention
my $last_pub_command = undef;
my $last_pub_command_time = 0;
my $pubmsg_throttle = 25;

sub set_pub_cmd {
    $last_pub_command = shift;
    $last_pub_command_time = time();
}

sub can_do_pub_cmd {
    my $cmd = shift || undef;
    my $samecase = shift || undef;
    my $return = 1;

    $cmd =~ tr/A-Z/a-z/ if (!(defined $samecase));
    if ((defined $last_pub_command) && ($last_pub_command eq $cmd)) {
	$return = 0 if (time() < ($last_pub_command_time + $pubmsg_throttle));
    }
    set_pub_cmd($cmd);
    return $return;
}




sub sqlquery_subthread {
    my $query;
    my $channel;
    my $nick;
    while (1) {
	sleep(2);
	$query = $querythread_input->peek();
	if ($query && $querythread_input->pending()) {

	    my @tmp = split(/\t/, $query);
	    $channel = $tmp[0];
	    $nick = $tmp[1];
	    $query = $tmp[2];

	    db_connect();
	    my $str = do_sqlquery_xlogfile($channel, $nick, $query);
	    db_disconnect();
	    {
		lock(@querythread_output);
		push(@querythread_output, $channel."\t".$nick."\t".$str);
	    }
	    $querythread_input->dequeue();
	}
    }
}



sub paramstr_sqlquery_xlogfile {
    my $query = shift || "";

    db_connect();
    return "Xlogfile db disabled." if (!$dbh);
    my %dat = mangle_sql_query($query, undef, undef, 1);

    if ($dat{"error"}) {
	db_disconnect();
	return "";
    }

    my $sth = $dbh->prepare($dat{"sql"});

    if ($dbh->err() || !$sth) {
	db_disconnect();
	return "";
    }

    my $dbdata;

    $sth->execute();

    my @dbl;

    while ($dbdata = $sth->fetchrow_hashref()) {
	foreach my $a (keys %$dbdata) {
	    push(@dbl, decode_xlog_datastr($a, $dbdata->{$a}));
	}
    }

    db_disconnect();

    return join("|", @dbl);
}

sub do_sqlquery_xlogfile {
    my ($channel, $nick, $query) = @_;

    my $show_dump = 0;
    my $show_ttyrec = 0;
    my $offset = 0;

    my @ret;

    if ($query =~ m/\s?-?-dump\s/i) {
	$show_dump = 1;
	$query =~ s/\s?-?-dump\s/ /i;
	$query = $query . " starttime name"; # we need starttime and name to show dumps
    } elsif ($query =~ m/\s?-?-ttyrec\s/i) {
	$show_ttyrec = 1;
	$query =~ s/\s?-?-ttyrec\s/ /i;
	$query = $query . " starttime name";
    }

    if ($query =~ m/\s?-?-count\s/i) {
	my $do_count = 1;
	$query =~ s/\s?-?-count\s/ /i;
	my %dat = mangle_sql_query($query, $nick, $do_count);
	if ($dat{"error"}) {
	    push(@ret, $dat{"error"});
	    if ($channel eq "paxed") {
		push(@ret, "sql:'".$dat{"sql"}."'") if ($dat{"sql"});
		push(@ret, "query:'".$query."'");
	    }
	} else {
	    my $sth = $dbh->prepare($dat{"sql"});

	    push (@ret, "$DBI::errstr") if ($dbh->err());

	    if ($sth) {
		$sth->execute();
		my ($count_num) = $sth->fetchrow_array();
		if ($channel eq "paxed") {
		    push(@ret, "sql:'".$dat{"sql"}."'") if ($dat{"sql"});
		    push(@ret, "query:'".$query."'");
		}
		push(@ret, "That query has ".$count_num." matches.");
	    }
	}
	return join("\n", @ret);
    }

    my %dat = mangle_sql_query($query, $nick);

    $offset = $dat{"offset"} if ($dat{"offset"});

    if ($dat{"error"}) {
	push(@ret, $dat{"error"});
	if ($channel eq "paxed") {
	    push(@ret, "sql:'".$dat{"sql"}."'") if ($dat{"sql"});
	    push(@ret, "query:'".$query."'");
	}
    } else {
	my $str = "";
	my $dbdata;
	return ("Xlogfile db disabled.") if (!$dbh);
	my $sth = $dbh->prepare($dat{"sql"});

	if ($dbh->err()) { push(@ret, "$DBI::errstr"); last; }

	my $nresults = 0;
	my $a;
	my $b;
	my @gotfields = split(",", $dat{"fields"});
	my $count_dumps = 0;
	if ($sth) {
	    $sth->execute();
	    my $got_no_dump = 0;
	    while ($dbdata = $sth->fetchrow_hashref()) {

		if ($show_dump) {
		    my $dumpfile = fixstring($nh_dumppath, %$dbdata);
		    if (-e "$dumpfile") {
			next if ($count_dumps >= 3);
			my $url = fixstring($nh_dumpurl, %$dbdata);
			push(@ret, $url);
			$count_dumps++;
		    } else {
			if (!$got_no_dump) {
			    push(@ret, "Sorry, no dump file found for a game by ".$dbdata->{'name'}.".");
			    $got_no_dump = 1;
			}
		    }
		} elsif ($show_ttyrec) {
		    my $ttyrecfile = fixstring($userdata_ttyrec, %$dbdata);
		    if (-e "$ttyrecfile") {
			next if ($count_dumps >= 1);
			my $url = fixstring($userdata_ttyrec_puburl, %$dbdata);
			push(@ret, $url);
			$count_dumps++;
		    } else {
			my $ttyrecfilebz2 = $ttyrecfile.".bz2";
			if (-e "$ttyrecfilebz2") {
			    next if ($count_dumps >= 1);
			    my $url = fixstring($userdata_ttyrec_puburl.".bz2", %$dbdata);
			    push(@ret, $url);
			    $count_dumps++;
			} else {
			    if (!$got_no_dump) {
				push(@ret, "Sorry, no dump file found for a game by ".$dbdata->{'name'}.".");
				$got_no_dump = 1;
			    }
			}
		    }
		}

		my %dbl;
	        $nresults += 1;
		$str = $str . ";  " if ($str);
		foreach $a (keys %$dbdata) {
		    $b = decode_xlog_datastr($a, $dbdata->{$a});
		    $dbl{$a} = $b;
		}
		my @tmpdbl;
		foreach $a (@gotfields) {
		    push(@tmpdbl, $dbl{$a});
		}
		$str = $str . ($nresults+$offset).") ".join(",", @tmpdbl);
	    }

	    if (!$show_dump && !$show_ttyrec) {
		if ($nresults) {
		    push(@ret, $dat{"fields"}.": ".$str);
		} else {
		    push(@ret, "No matches for that query.");
		}
	    }
	    if ($channel eq "paxed") {
		push(@ret, "sql:'".$dat{"sql"}."'") if ($dat{"sql"});
		push(@ret, "query:'".$query."'");
	    }
	} else {
	    push(@ret, "error with dbh->prepare");
	    push(@ret, "sql:'".$dat{"sql"}."'");
	}
    }
    return join("\n", @ret);
}

sub cancel_xlogfile_query {
    my ($self, $channel, $nick) = @_;

    lock($querythread_input);

    my $nqueue = $querythread_input->pending();
    while ($nqueue > 0) {
	$nqueue--;
	my ($chn, $nck, $qry) = split(/\t/, $querythread_input->peek($nqueue));
	if (lc($nck) eq lc($nick) && lc($chn) eq lc($channel)) {
	    if (!$nqueue) {
		$self->botspeak("$nick: Too late.", $channel);
	    } else {
		$self->botspeak("$nick: OK, cancelled.", $channel);
		$querythread_input->extract($nqueue);
	    }
	    return;
	}
    }
}

sub do_pubcmd_query_xlogfile {
    my ($self, $channel, $nick, $query) = @_;

    my $nqueue = $querythread_input->pending();
    while ($nqueue > 0) {
	$nqueue--;
	my ($chn, $nck, $qry) = split(/\t/, $querythread_input->peek($nqueue));
	if (lc($nck) eq lc($nick)) {
	    $self->botspeak("$nick: You've got a query in the queue already.", $channel);
	    return;
	}
    }

    $querythread_input->enqueue($channel."\t".$nick."\t".$query);

#    db_connect($self);
#    my $str = do_sqlquery_xlogfile($channel, $nick, $query);
#    db_disconnect();

#    $self->botspeak($str, $channel);
}

sub do_pubcmd_version {
    my ($self, $channel) = @_;
    $self->botspeak($self->{'Version'}, $channel);
}

sub do_pubcmd_seen {
    my ($self, $channel, $nick, $name) = @_;
    if ($name) {
	$name =~ tr/A-Z/a-z/;
	my $fseen = $seen_db->seen_get($name) || undef;
	my $mynick = $self->{'Nick'};
	$mynick =~ tr/A-Z/a-z/;

	if ($name eq $nick) {
	    $self->botspeak("Looking for yourself, $nick?", $channel);
	}
	elsif ($name eq $mynick) {
	    $self->botspeak("I'm right here, foo!", $channel);
	}
	elsif (defined $fseen) {
	    $self->botspeak($fseen, $channel);
	}
	else {
	    $self->botspeak("Sorry, $nick, I haven't seen $name.", $channel);
	}
    }
    else {
	$self->botspeak("Huh?  What? Where?  Who?", $channel);
    }
}

sub do_pubcmd_dbquery {
    my ($self, $channel, $tonickchan, $nick, $query) = @_;

    my @a;
    my $term_no;
    my $error;

    my ($term, $sendto, $errsto, $donotice) = extract_query_and_target($tonickchan, $query, $nick, $channel);
    if ($sendto ne $nick && $sendto ne $channel) {
	if (!$seen_db->seen_get($sendto)) {
	    $self->botspeak("$nick: I don't know $sendto.", $channel, $donotice);
	    return;
	}
    }

    # requested just one term, with foo[N]
    if ($term =~ /^(.+)\[(\d+)\]\s*$/) {
	$term = $1;
	$term_no = $2;
    }

    $term =~ s/ +$//;
    $term =~ tr/ /_/;

    if (lc $self->{'Nick'} eq lc $sendto) {
	$self->botspeak("$nick: I already know that.", $channel);
	return;
    }

    @a = $learn_db->query($term);
    if (@a == 0) {
	$self->botspeak("$term not found in dictionary. Trying a search.", $errsto, $donotice);
	@a = $learn_db->search($term, \$error);

	# on error, messages go to the requester
	$sendto = $errsto if $error;
    }

    # 7/1/2005 11:08AM: (Stevie-O) Prevent ?> flooding
    if (!$term_no && @a > $self->{'SpeakLimit'} && $sendto =~ /^#/) {
        # send this instead
	@a = ("That entry is a little too long. See ".$self->{'learn_url'}.uri_escape($term));
    }

    if (lc $sendto ne lc $errsto) {
	$self->botspeak("This definition is sent to you by $nick.", $sendto, $donotice);
    }

    if ($term_no) {
	my $b = $#a + 1;
	if ($term_no > $b) {
	    $self->botspeak("There's only $b definition"
			    .(($b > 1) ? "s" : "").
			    " for $term.", $errsto, $donotice);
	} else {
	    $self->botspeak($a[$term_no-1], $sendto, $donotice);
	}
    } else {
	foreach $b (@a) {
	    $self->botspeak($b, $sendto, $donotice);
	}
    }

    if (lc $sendto ne lc $errsto) {
	$self->botspeak("Definition sent to $sendto.", $nick, $donotice);
    }
}

sub do_pubcmd_dbsearch {
    my ($self, $channel, $tonickchan, $nick, $query) = @_;

    my @a;
    my $error;

    my ($term, $sendto, $errsto, $donotice) = extract_query_and_target($tonickchan, $query, $nick, $channel);

    if ($sendto ne $nick && $sendto ne $channel) {
	if (!$seen_db->seen_get($sendto)) {
	    $self->botspeak("I don't know $sendto.", $errsto, $donotice);
	    return;
	}
    }

    my @searchresult = $learn_db->search($term, \$error);

    # if something went wrong, all messages go to the requester
    $sendto = $errsto if $error;

    if (lc $sendto ne lc $errsto) {
	$self->botspeak("This definition is sent to you by $nick.", $sendto, $donotice);
    }

    if (@searchresult > $self->{'SpeakLimit'} && $sendto =~ /^#/) {
	@searchresult = ("Search result is a little too long. See ".$self->{'learn_url'}.uri_escape($term));
    }

    foreach $a (@searchresult) {
	$self->botspeak($a, $sendto, $donotice);
    }

    if (lc $sendto ne lc $errsto) {
	$self->botspeak("Definition sent to $nick", $nick, $donotice);
    }
}

sub do_pubcmd_dbinfo {
    my ($self, $channel, $query) = @_;
    my $a;
    foreach $a ($learn_db->info($query)) {
	$self->botspeak($a, $channel);
    }
}

sub do_pubcmd_dbedit {
    my ($self, $channel, $term, $tnum, $edita, $editb, $opts) = @_;

    $tnum =~ s/ //g if (defined $tnum);

    # requested just one term, with foo[N]
    if (!$tnum && ($term =~ /^(.+)\[(\d+)\]\s*$/)) {
	$term = $1;
	$tnum = $2;
    }

    if ($tnum) {
	foreach $a ($learn_db->edit($term, $tnum, $edita, $editb, $opts)) {
	    $self->botspeak($a, $channel);
	}
    } else {
	$self->botspeak("Term number required.", $channel);
    }
}

sub do_pubcmd_dbdelete {
    my ($self, $channel, $term, $num) = @_;
    # requested just one term, with foo[N]
    if (!$num && ($term =~ /(.+)\[(\d+)\]$/)) {
	$term = $1;
	$num = $2;
    }

    my $a;
    foreach $a ($learn_db->del($term,$num)) {
	$self->botspeak($a, $channel);
    }
}

sub do_pubcmd_dbswap {
    my ($self, $channel, $terma, $termb) = @_;
    my $terman = 1;
    my $termbn = 1;
    my $a;

    if ($terma =~ /(.+)\[(\d+)\]$/) {
	$terma = $1;
	$terman = $2;
    }
    if ($termb =~ /(.+)\[(\d+)\]$/) {
	$termb = $1;
	$termbn = $2;
    }

    foreach $a ($learn_db->swap($terma,$terman, $termb,$termbn)) {
	$self->botspeak($a, $channel);
    }
}

sub do_pubcmd_dbdebug {
    my ($self, $channel) = @_;
    my $a;

    foreach $a ($learn_db->debug()) {
	$self->botspeak($a, $channel);
    }
}

sub do_pubcmd_dbadd {
    my ($self, $channel, $nick, $term, $def) = @_;
    my $a;

    foreach $a ($learn_db->add($term,$nick,$def)) {
	$self->botspeak($a, $channel);
    }
}


sub do_pubcmd_bugs {
    my ($self, $channel, $bugid) = @_;

    my $bugs = $buglist_db->search_bugs($bugid);
    if ($bugs) {
	$self->botspeak("$bugs", $channel);
    }
}

sub do_pubcmd_gamesby {
    my ($self, $channel, $name) = @_;
    $name =~ tr/A-Z/a-z/;
    my $a = $self->log_data($name);
    $self->botspeak($a, $channel);
}

sub do_pubcmd_ascensions {
    my ($self, $channel, $name) = @_;
    $name =~ tr/A-Z/a-z/;
    my $a = $self->asc_data($name);
    $self->botspeak($a, $channel);
}

sub do_pubcmd_streak {
    my ($self, $channel, $nick) = @_;
    $nick =~ tr/A-Z/a-z/;

    my $longstreak = 0;
    my $longstart  = '';
    my $longend    = '';
    my $curstreak  = 0;
    my $curstart   = '';
    my $curend     = '';
    my $games      = 0;
    my $cancont    = 0;
    my $cancontlong = 0;

    db_connect($self);
    if (!$dbh) {
	$self->botspeak("Xlogfile db disabled", $channel);
	return;
    }
    my $sth = $dbh->prepare("SELECT birthdate,deathdate,death FROM xlogfile WHERE name LIKE ".$dbh->quote($nick));
    $sth->execute();

    while (my $dbdata = $sth->fetchrow_hashref()) {

	    $games++;
	    if ($dbdata->{death} eq 'ascended') {
		if ($curstreak == 0) {
		    $curstart = $dbdata->{birthdate};
		} else {
		    $curend = $dbdata->{deathdate};
		}
		$curstreak++;
		$cancont = 1;
		if ($curstreak > $longstreak) {
		    $cancontlong = 1;
		}
	    } else {
		if ($curstreak > $longstreak) {
		    ($longstreak, $longstart, $longend) = ($curstreak, $curstart, $curend);
		    $cancontlong = 0;
		}
		($curstreak, $curstart, $curend) = (0, '', '');
		$cancont = 0;
	    }


    }
    db_disconnect();

    if ($curstreak > $longstreak) {
	($longstreak, $longstart, $longend) = ($curstreak, $curstart, $curend);
    }

    my $msg;

    if ($longstreak > 1) {
	$msg = "$nick has ascended $longstreak games in a row, between $longstart and $longend";
	$msg .= ", and can continue the streak" if ($cancontlong);
	$msg .= ".";
	if ($cancont && !$cancontlong) {
	    if ($curstreak == 1) {
		$msg .= " $nick\'s latest game ended in an ascension.";
	    } else {
		$msg .= " $nick is currently on a streak of $curstreak games.";
	    }
	}
    } elsif ($longstreak == 1) {
	$msg = "$nick has never ascended more than once in a row";
	$msg .= " (but can still make it a streak)" if ($cancontlong);
	$msg .= ".";
    } elsif ($games) {
	$msg = sprintf('%s has not ascended in %d game%s.', $nick, $games, $games == 1 ? '' : 's');
    } else {
	$msg = "No games for $nick.";
    }

    $self->botspeak($msg, $channel);
}

sub do_pubcmd_gamenum {
    my ($self, $channel, $gamenum, $name) = @_;
    $name =~ tr/A-Z/a-z/ if (defined $name);

    my $speakstr;

    if ($name) {
	my @lines = $self->player_logfile($name);
	my $numlines = @lines;
	if ($gamenum > $numlines) {
	    $speakstr = "$name has played only $numlines games so far.";
	} elsif ($gamenum > 0) {
	    $speakstr = "Game #$gamenum/$numlines: ".demunge_recordline(xlog2record($lines[($gamenum-1)]), 5);
	} elsif ($gamenum < 0 && $gamenum > -$numlines) {
	    $gamenum = $numlines + $gamenum + 1;
	    $speakstr = "Game #$gamenum/$numlines: ".demunge_recordline(xlog2record($lines[$gamenum-1]), 5);
	} else {
	    $speakstr = "What game?";
	}
    } else {
	my $line;
	if ($gamenum > 0) {
	    $line = `head -$gamenum "$self->{'nh_logfile'}" | tail -1`;
	} elsif ($gamenum < 0) {
	    my $tmpgamenum = -$gamenum;
	    $line = `tail -$tmpgamenum "$self->{'nh_logfile'}" | head -1`;
	}
	$line =~ s/\n+$//;
	if ($line =~ m/version=/) {
	    $speakstr = "Game #$gamenum: ".demunge_recordline(xlog2record($line), 5);
	} else {
	    $speakstr = "No such game."
	}
    }
    $self->botspeak($speakstr, $channel);
}

sub do_pubcmd_lastgame {
    my ($self, $channel) = @_;

    if ($last_played_game) {
	foreach $a (demunge_recordline($last_played_game, 5)) {
	    $self->botspeak($a, $channel);
	}
    } else {
	$self->botspeak("I haven't seen any games yet.", $channel);
    }
}

sub do_pubcmd_scores {
    my ($self, $channel, $name) = @_;
    $name =~ tr/A-Z/a-z/;
    my @b = $self->highscore_query_nick($name);
    if ($b[0] =~ m/Player .* not on highscore list./i) {
	$self->botspeak($b[0], $channel);
    } else {
	$self->botspeak($self->{'PublicScorePath'}.$name, $channel);
    }
}

sub do_pubcmd_hsn {
    my ($self, $channel, $name) = @_;
    $name =~ tr/A-Z/a-z/;
    foreach $a ($self->highscore_query_nick($name)) {
	$self->botspeak($a, $channel);
    }
}

sub do_pubcmd_players {
    my ($self, $channel,$nick) = @_;
    my @plrs = $self->current_players();
    my $a;
    foreach $a (@plrs) {
	$self->botspeak($a, $channel);
    }
}


sub do_pubcmd_lvlfiles {
    my ($self, $channel, $name) = @_;
    my $username = $name;
    my $findname = '^5'.$username.'\.[0-9]+$';
    my @files = find_files($self->{'NHLvlFiles'}, $findname);

    if ($#files < 0) {
	$self->botspeak("No level lock files for user $name", $channel);
    } else {
	my $nlvlfiles = $#files + 1;
	$self->botspeak("$name has $nlvlfiles level file". (($nlvlfiles > 1) ? "s" : ""), $channel);
    }
}

sub do_pubcmd_savefiles {
    my ($self, $channel, $name) = @_;
    my $username = $name;
    my $findname = '^5'.$username.'\.gz$';
    my $savedir = $self->{'nh_savefiledir'};
    my @files = find_files($savedir, $findname);

    if ($#files < 0) {
	$self->botspeak("No save file for user $name", $channel);
    } else {
	my $ftime = (stat($savedir.$files[0]))[9];
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($ftime);
	my $ret = sprintf("%04d%02d%02d %02d:%02d:%02d", ($year+1900), ($mon+1), $mday, $hour,$min,$sec);
	$self->botspeak("$name has a save file, last updated at $ret", $channel);
    }
}

sub do_pubcmd_rcfile {
    my ($self, $channel, $input) = @_;
    my $name = $self->userdata_name($input) or do {
        $self->botspeak("No config file for $input.", $channel);
        return;
    };

    my %namehash = (name=>$name);
    my $rc = fixstring($self->{'userdata_rcfile_puburl'}, %namehash);
    $self->botspeak($rc, $channel);
}

sub do_pubcmd_lastlog {
    my ($self, $channel, $name) = @_;
    my $username = $name;

    if (my $url = $self->dumplog_url($username)) {
       $self->botspeak($url, $channel);
    } else {
       $self->botspeak("No lastgame dump file for $username.", $channel);
    }
}

# Common commands for both privmsg and public
sub priv_and_pub_msg {
    my ( $self, $channel, $nick, $msg ) = @_;

    if ($msg =~ m/^!lg\s+-?-cancel/i ||
	$msg =~ m/^!lg\s+-?-rm/i ||
	$msg =~ m/^!rmlg\s+.*$/i ||
	$msg =~ m/^!rmlg\s*$/i) {
# !lg --cancel *
# !rmlg *
	$self->cancel_xlogfile_query($channel, $nick);
    }
    elsif ($msg =~ m/^!lg\s+(.+)\s*$/i) {
# !lg *
	$self->do_pubcmd_query_xlogfile($channel, $nick, $1);
    }
    elsif ($msg =~ m/^!lg\s*$/i) {
	$self->do_pubcmd_query_xlogfile($channel, $nick, $nick);
    }
    elsif ( $msg =~ m/^!version$/i ) {
# !version
	$self->do_pubcmd_version($channel);
    }
    elsif ( $msg =~ m/^!rn[gd]\s+(.+)$/i ) {
# !rng, !rnd
	$self->botspeak(rng_choice($1, 1), $channel);
    }
    elsif ( $msg =~ m/^!seen/i ) {
# !seen nick
        my @arg = split ( / /, $msg );
        my $name = $arg[1];
	$self->do_pubcmd_seen($channel,$nick,$name);
    }
    elsif ( $msg =~ m/^!(message|tell)\s+(\S+)\s+(\S.+)$/i ) {
# !message nick text
	my $target_nick = $2;
	my $text = $3;
	if (lc($nick) eq lc($target_nick)) {
	    $self->botspeak("$nick: Tell yourself.", $channel);
	} elsif (lc($self->{'Nick'}) eq lc($target_nick)) {
	    $self->botspeak("$nick: Got it.", $channel);
	} else {
	    $user_messages_db->leave_message($target_nick, $nick, $text);
	    $self->botspeak("OK, I'll let $target_nick know.", $channel);
	}
    }
    elsif ( $msg =~ m/^!messages?\s*$/i ) {
# !message or !messages
	my $usrmsgs = $user_messages_db->get_messages($nick);
	if ($usrmsgs) {
	    $self->botspeak($usrmsgs, $channel);
	}
    }
    elsif ($msg =~ m/^!learn\s+info\s+(.+)$/i) {
# !learn info foo
        my $term = $1;
	$term =~ s/ /_/g;
	$self->do_pubcmd_dbinfo($channel,$term);
    }
    elsif ($msg =~ m/^!games(?:by)?\s(\S+)\s*$/i) {
# !gamesby <name>
	my $plr = $1;
	$self->do_pubcmd_gamesby($channel, $plr);
    }
    elsif ($msg =~ m/^!games(?:by)?\s*$/i) {
# !gamesby
	$self->do_pubcmd_gamesby($channel,$nick);
    }
    elsif ($msg =~ m/^!streak(\s+\S+\s*)?$/) {
# !streak <name>
	my $plr = $1 || $nick;
	$plr =~ s/^\s+//;
	$self->do_pubcmd_streak($channel, $plr);
    }
    elsif ($msg =~ m/^!asc(?:ensions?)?\s+(\S+)\s*$/i) {
# !ascension <name>
# !ascensions <name>
	my $plr = $1;
	$self->do_pubcmd_ascensions($channel, $plr);
    }
    elsif ($msg =~ m/^!asc(?:ensions?)?\s*$/i) {
# !ascension
# !ascensions
	$self->do_pubcmd_ascensions($channel,$nick);
    }
    elsif ($msg =~ m/^!gamenum\s+(-?\d+)\s*(\S*)\s*$/i) {
	my $gamenum = $1;
	my $plr = $2 || undef;
	$self->do_pubcmd_gamenum($channel, $gamenum, $plr);
    }
    elsif ($msg =~ m/^!grepsrc\s(.+)$/i) {
	$self->botspeak(dogrepsrc($1), $channel);
    }
    elsif ($msg =~ m/^!lastgame$/i) {
# !lastgame
	$self->do_pubcmd_lastgame($channel);
    }
    elsif ($msg =~ m/^!scores?\s+(\S+)\s*$/i) {
# !scores <name>
	my $plr = $1;
	$self->do_pubcmd_scores($channel,$plr);
    }
    elsif ($msg =~ m/^!scores\s*$/i) {
# !scores
	$self->do_pubcmd_scores($channel,$nick);
    }
    elsif ($msg =~ m/^!hsn\s+(\S+)\s*$/i) {
# !hsn <name>
# !hsn #<number>
	my $plr = $1;
	$self->do_pubcmd_hsn($channel,$plr);
    }
    elsif ($msg =~ m/^!hsn\s*$/i) {
# !hsn
	$self->do_pubcmd_hsn($channel,$nick);
    }
    elsif ($msg =~ m/^!players?\s*$/i) {
# !player
# !players
	$self->do_pubcmd_players($channel,$nick);
    }
    elsif ($msg =~ m/^!whereis\s*(\S+)?$/i) {
# !whereis
# !whereis <name>
# !whereis --<sortfield>
	my $sort = undef;
	my $plr = undef;
	my $parm = $1 || "";
	if ($parm =~ m/^--?/) {
	    $sort = $parm;
	} else {
	    $plr = $parm;
	}
	my $plrs = $self->whereis_players($plr, $sort);
	if ($plrs eq "") {
	    if ($plr) {
		$plrs = "$plr is not playing right now.";
	    } else {
		$plrs = "No players right now.";
	    }
	}
	$self->botspeak($plrs, $channel);
    }
    elsif ($msg =~ m/^!lvlfiles\s+(\S+)$/i) {
# !lvlfiles <name>
	$self->do_pubcmd_lvlfiles($channel, $1);
    }
    elsif ($msg =~ m/^!lvlfiles\s*$/i) {
# !lvlfiles
	$self->do_pubcmd_lvlfiles($channel, $nick);
    }
    elsif ($msg =~ m/^!save\s+(\S+)$/i) {
# !save <name>
	$self->do_pubcmd_savefiles($channel, $1);
    }
    elsif ($msg =~ m/^!save\s*$/i) {
# !save
	$self->do_pubcmd_savefiles($channel, $nick);
    }
    elsif (($msg =~ m/^!rc(?:file)?\s+(\S+)/i) ||
	   ($msg =~ m/^!nethackrc\s+(\S+)/i)) {
# !rc <name>
# !rcfile <name>
# !nethackrc <name>
	$self->do_pubcmd_rcfile($channel, $1);
    }
    elsif (($msg =~ m/^!rc(?:file)?\s*/i) ||
	   ($msg =~ m/^!nethackrc\s*/i)) {
# !rc
# !rcfile
# !nethackrc
	$self->do_pubcmd_rcfile($channel, $nick);
    }
    elsif (($msg =~ m/^!dump(?:log)?\s+(\S+)/i) ||
	   ($msg =~ m/^!lastlog\s+(\S+)/i) ||
	   ($msg =~ m/^!lastgame\s+(\S+)/i)) {
# !dumplog <name>
# !lastlog <name>
# !lastgame <name>
	$self->do_pubcmd_lastlog($channel,$1);
    }
    elsif (($msg =~ m/^!dump(?:log)?\s*/i) ||
	   ($msg =~ m/^!lastlog\s*/i)) {
# !dumplog
# !lastlog
	$self->do_pubcmd_lastlog($channel,$nick);
    }
    elsif ($msg =~ m/^!bugs?\s*(.*)$/i) {
# !bug
# !bugs
	my $bugid = $1 || "";
	$self->do_pubcmd_bugs($channel, $bugid);
    }
    elsif ($msg =~ m/^!learn\s+debug$/i ||
           $msg =~ m/^!learn\s+info$/i) {
# !learn debug
# !learn info
	$self->do_pubcmd_dbdebug($channel);
    }
    elsif ( $msg =~ m/^(\*[\*\>\<])\s*(.+)/i ) {
# *> foo
# ** foo
	my $tonickchan = $1;
	my $query = $2;
	$self->do_pubcmd_dbsearch($channel,$tonickchan,$nick,$query);
    }
    elsif (($msg =~ m/^(\?[\?\>\<])\s*(.+)$/i)) {
# ?> foo
# ?? foo
# ?? foo > nickchan
# ?? foo >> nickchan
#   if foo is of form foo[N], show just the definition N.
#   nickchan can be either a nick or a channel.
	my $tonickchan = $1;
	if ($tonickchan =~ m/^\!/i) {
	    $tonickchan = '?>';
	}
	$self->do_pubcmd_dbquery($channel,$tonickchan,$nick,$2);
    } else {
	return 1;
    }
    return 0;
}

sub check_messages {
    my ($self, $nick, $channel) = @_;
    my $n_messages = $user_messages_db->have_messages($nick);
    if ($n_messages) {
	if ($n_messages > 1) {
	    $self->botspeak("$nick: You have $n_messages messages. Use !messages to read them.", $channel);
	} else {
	    my $usrmsg = $user_messages_db->get_messages($nick);
	    $self->botspeak("$nick, I have a message for you: $usrmsg", $channel);
	}
    }
}


my %channel_log_data = ();

sub log_channel_msg {
    my ( $self, $channel, $nick, $msg ) = @_;

    return if (!($channel =~ m/^#/));

    $channel =~ tr/A-Z/a-z/;

    if (!defined $channel_log_data{$channel}) {
	my $path = (!defined $self->{'LogPath'}) ? $ENV{'HOME'} : $self->{'LogPath'};
	my $chan = $channel;
	my $logf = "$path/channels/$chan.log";
	if (open(my $tmpfile, ">>$logf")) {
	    $channel_log_data{$channel} = { flushtime => 0, filehandle => $tmpfile, disabled => 0 };
	} else {
	    debugprint("Failed to open channel log file $logf.");
	    $channel_log_data{$channel} = { disabled => 1 };
	}
    }

    return if ($channel_log_data{$channel}{disabled});

    my $time = localtime( time() );
    my $fh = $channel_log_data{$channel}{filehandle};
    print $fh "[$time] <$nick> $msg\n";

    if (time > $channel_log_data{$channel}{flushtime} + 30) {
	my $ofh = select $fh;
	$| = 1;
	print $fh "";
	$| = 0;
	select $ofh;
	$channel_log_data{$channel}{flushtime} = time;
    }
}

sub log_channel_msg_flush {
    foreach my $channel (keys %channel_log_data) {
	next if ($channel_log_data{$channel}{disabled});
	my $fh = $channel_log_data{$channel}{filehandle};
	my $ofh = select $fh;
	$| = 1;
	print $fh "";
	$| = 0;
	select $ofh;
	$channel_log_data{$channel}{flushtime} = time;
    }
}


# paramstr_if("str_a|str_b|do_if_equal|do_if_not_equal")
# paramstr_if("integer_boolean_value|do_if_non-zero|do_if_zero")
# paramstr_if("integer_boolean_value|do_if_non-zero")
sub paramstr_if {
    my $str = shift;
    if ($str =~ m/^(.*)\|(.*)\|(.*)\|(.*)$/) {
	my $stra = $1;
	my $strb = $2;
	my $do_eq = $3 || "";
	my $do_ne = $4 || "";
	if ($stra eq $strb) {
	    return parse_strvariables_core($do_eq);
	} else {
	    return parse_strvariables_core($do_ne);
	}
    } elsif ($str =~ m/^(.*)\|(.*)\|(.*)$/) {
	my $bool = $1;
	my $do_eq = $2 || "";
	my $do_ne = $3 || "";
	if (paramstr_isint($bool) && (int $bool)) {
	    return parse_strvariables_core($do_eq);
	} else {
	    return parse_strvariables_core($do_ne);
	}
    } elsif ($str =~ m/^(.*)\|(.*)$/) {
	my $bool = $1;
	my $do_eq = $2 || "";
	if (paramstr_isint($bool) && (int $bool)) {
	    return parse_strvariables_core($do_eq);
	}
    }
    return "";
}


sub is_learndb_trigger {
    my $str = lc(shift);
    return 1 if ($str =~ m/^#([a-z]+|\*):/);
    return 0;
}

sub can_edit_learndb {
    my $nick = shift;
    my $term = shift;
    if (is_learndb_trigger($term)) {
	return 1 if ($admin_nicks->is_identified($nick));
	return 0;
    }
    return 1;
}

sub paramstr_isadmin {
    my $s = shift || "";
    return "1" if ($admin_nicks->is_identified($s));
    return "0";
}

my @sorted_paramrepl_keys;
my %strvariables_paramrepls;
my $strvariables_processing; # 0=keep doing until finished. 1=quit, return current result, 2=quit with no result
my %strvariables_vars = ();

sub paramstr_setvar {
    my $s = shift || "";
    if ($s =~ m/^(.+)\|(.*)$/) {
       my $varname = $1;
       my $varvalue = $2 || "";
       if ($varname =~ m/^(.+)\[(.+)\]$/) {
	   $varname = $1;
	   my $varidx = $2;
	   $strvariables_vars{$varname}->[$varidx] = $varvalue;
       } else {
	   $strvariables_vars{$varname} = $varvalue;
       }
    }
    return "";
}

sub paramstr_getvar {
    my $s = shift || "";
    if ($s =~ m/^(.+)\[(.+)\]$/) {
	$s = $1;
	my $idx = $2;
	return $strvariables_vars{$s}->[$idx] if ($strvariables_vars{$s}->[$idx]);
    } else {
	return $strvariables_vars{$s} if ($strvariables_vars{$s});
    }
    return "";
}

sub paramstr_clearvars { %strvariables_vars = (); }


sub paramstr_stop_process {
    my $s = shift || "0";
    if (($s =~ m/^\d+$/) && (int($s) > 0)) {
	$strvariables_processing = 2;
    } else {
	$strvariables_processing = 1;
    }
    return "";
}

sub paramstr_maybestop {
    my $s = paramstr_trim(shift) || "0";
    if (($s =~ m/^\d+$/) && (int($s) > 0)) {
	$strvariables_processing = 2 if (int(rand(int($s))));
    }
    return "";
}

sub parse_strvariables_core {
    my $str = shift || "";

    my $found;

    do {
	$found = 0;
        if ($str =~ m/^(.*?)(\$.*)$/) {
            my $prefix = $1 || "";
            my $maybevar = $2 || "";
            foreach my $tmp (@sorted_paramrepl_keys) {
                if (ref($strvariables_paramrepls{$tmp}) =~ m/CODE/) {
                    if ($maybevar =~ m/^\Q$tmp\E(\(.+)$/) { # Functions: $FOO(...)
                        my $after  = $1 || "";
                        my $inner  = get_inner_str($after);
                        my $suffix = substr($after, length($inner)+2);
                        my $middle = &{ $strvariables_paramrepls{$tmp} }(parse_strvariables_core($inner));
                        $str = $prefix.$middle.(($strvariables_processing == 0) ? $suffix : "");
                        $found = 1;
                        last;
                    }
                } else {
                    if ($maybevar =~ m/^\Q$tmp\E(.*)$/) { # Constants: $FOO
                        my $suffix = $1 || "";
                        $str = $prefix . $strvariables_paramrepls{$tmp} . $suffix;
                        $found = 1;
                        last;
                    }
                }
            }
	    if ($found == 0 && ($maybevar =~ m/^\$/)) {
		$maybevar =~ s/^\$/\x03/;
		$str = $prefix . $maybevar;
	    }
        }
    } while ($found && ($strvariables_processing == 0));

    return $str;
}

sub parse_strvariables {
    my ($self, $channel, $nick, $cmdargs, $string) = @_;

    $cmdargs = "" if (!defined $cmdargs);

    $cmdargs =~ s/\s+/ /g;
    $cmdargs =~ s/\$/\x03/g;

    my @arglist = split(/ /, paramstr_escape(paramstr_trim($cmdargs)));
    shift @arglist;

    my $argr = $arglist[rand(@arglist)] || $nick;
    my $args = (join ' ', @arglist) || $nick;
    my $rnd_nh_char = random_nh_char();
    my $rnd_monster = $nh_monsters[rand(@nh_monsters)];
    my $rnd_object = $nh_objects[rand(@nh_objects)];
    my $rnd_buc = $nhconst::BUC[rand(@nhconst::BUC)];
    my $rnd_role_s = lc($nhconst::roles[rand(@nhconst::roles)]);
    my $rnd_race_s = lc($nhconst::races[rand(@nhconst::races)]);
    my $rnd_align_s = lc($nhconst::aligns[rand(@nhconst::aligns)]);
    my $rnd_gender_s = lc($nhconst::genders[rand(@nhconst::genders)]);
    my $rnd_role_l = $nhconst::roles_long[rand(@nhconst::roles_long)];
    my $rnd_race_l = $nhconst::races_long[rand(@nhconst::races_long)];
    my $rnd_align_l = $nhconst::aligns_long[rand(@nhconst::aligns_long)];
    my $rnd_gender_l = $nhconst::genders_long[rand(@nhconst::genders_long)];
    my $uptime = sprintf("%d Days, %02d:%02d:%02d", (gmtime(time() - $^T))[ 7, 2, 1, 0 ]);
    my $serveruptime = sprintf("%d Days, %02d:%02d:%02d", (gmtime((split(/\./, `cat /proc/uptime`))[0]))[ 7, 2, 1, 0 ]);
    my $zorkmid = ((rand(2) == 0) ? 'heads' : 'tails');
    my @curr_players = $self->player_list();
    my $rnd_player = $curr_players[rand(@curr_players)];
    my $pom_str = get_pom_str();
    my $curdate = `date`;
    my $recent_nick = recent_nicks_getrnd();
    $curdate =~ s/\n$//;

    my $selfnick = $self->{'Nick'};
    my $str = $string;
    $str =~ s/\\\$/\x03/g; # escaped dollar signs

    %strvariables_paramrepls = (
	'$AN'         => \&an,
	'$PLURAL'     => \&makeplur,
	'$NPLURAL'    => \&paramstr_nplural,
	'$SSUFFIX'    => \&paramstr_possessive,
	'$URLENC'     => \&uri_escape,
	'$RND'        => \&paramstr_rnd,
	'$SHUFFLE'    => \&paramstr_shuffle,
	'$CHOICE'     => \&rng_choice,
	'$LC'         => \&paramstr_lc,
	'$LCFIRST'    => \&paramstr_lcfirst,
	'$UC'         => \&paramstr_uc,
	'$UCFIRST'    => \&paramstr_ucfirst,
	'$STRLEN'     => \&paramstr_strlen,
	'$SUBSTR'     => \&paramstr_substr,
	'$IF'         => \&paramstr_if,
	'$TRIM'       => \&paramstr_trim,
	'$INDEX'      => \&paramstr_index,
	'$RINDEX'     => \&paramstr_rindex,
	'$REVERSE'    => \&paramstr_reverse,
	'$REBASE'     => \&paramstr_rebase,
	'$RNDCHAR'    => \&random_nh_char,
	'$REPLACESTR' => \&paramstr_replacestr,
	'$ROT13'      => \&paramstr_rot13,
	'$TIMEFMT'    => \&paramstr_timefmt,
	'$LG'         => \&paramstr_sqlquery_xlogfile,
	'$RMPIPES'    => \&paramstr_rmpipes,
	'$CALC'       => \&paramstr_math,
	'$ESCAPE'     => \&paramstr_escape,
	'$UNESCAPE'   => \&paramstr_unescape,
	'$ISNUM'      => \&paramstr_isnum,
	'$ISINT'      => \&paramstr_isint,
	'$ISALPHA'    => \&paramstr_isalpha,
	'$ISALNUM'    => \&paramstr_isalphanum,
	'$ISPLR'      => \&paramstr_is_used_playername,
	'$PLRNAME'    => \&paramstr_playername,
	'$ISWIKIPAGE' => \&paramstr_iswikipage,
	'$NWIKIPAGES' => \&paramstr_nwikipages,
	'$WIKIPAGE'   => \&paramstr_wikipage,
	'$ORDIN'      => \&paramstr_ordin,
	'$STOP'       => \&paramstr_stop_process,
	'$QUIT'       => \&paramstr_maybestop,
	'$ISADMIN'    => \&paramstr_isadmin,
	'$SET'        => \&paramstr_setvar,
	'$GET'        => \&paramstr_getvar,
	'$'           => \&paramstr_getvar,
	'$GOD'        => \&paramstr_rndgod,
	'$NICK'   => $nick,
	'$RNICK'  => $recent_nick,
	'$CHAN'   => $channel,
	'$SELF'   => $selfnick,
	'$ARGS'   => $args,
	'$ARG'    => $argr,
	'$CHAR'   => $rnd_nh_char,
	'$RNDMON' => $rnd_monster,
	'$RNDOBJ' => $rnd_object,
	'$BUC'    => $rnd_buc,
	'$ROLE'   => $rnd_role_s,
	'$RACE'   => $rnd_race_s,
	'$ALIGN'  => $rnd_align_s,
	'$GENDER' => $rnd_gender_s,
	'$LROLE'   => $rnd_role_l,
	'$LRACE'   => $rnd_race_l,
	'$LALIGN'  => $rnd_align_l,
	'$LGENDER' => $rnd_gender_l,
	'$UPTIME'  => $uptime,
	'$SERVERUPTIME'  => $serveruptime,
	'$COIN'    => $zorkmid,
	'$PLAYER'  => $rnd_player,
	'$NPLAYERS' => scalar(@curr_players),
	'$POM'      => $pom_str,
	'$DATE'     => $curdate,
	'$ACT '      => "\x02ACT ",
	'$THEN '    => "\x02THEN "
	);

    @sorted_paramrepl_keys = sort { length($b) <=> length($a) } keys %strvariables_paramrepls if (!@sorted_paramrepl_keys);

    paramstr_clearvars();
    %strvariables_vars = (
	'argc' => scalar(@arglist),
	'argv' => \@arglist
	);

    $strvariables_processing = 0;

    $str = parse_strvariables_core($str);

    return "" if ($strvariables_processing == 2);

    $str =~ s/\x03/\$/g;

    return paramstr_unescape($str);
}

sub handle_learndb_trigger {
    my ( $self, $channel, $nick, $cmdargs, $output) = @_;

    my @arglist = split(/ /, $cmdargs);
    my $term = $channel.":".(@arglist ? $arglist[0] : $cmdargs);
    my @a;

    my $retval = 0;

    $output = $output || $channel;
    $term =~ s/ /_/g;
    @a = $learn_db->query($term);
    if (@a == 0) {
	$term = "#*:".$arglist[0];
	@a = $learn_db->query($term);
    }

    if (@a > 0) {

	my $b = $a[rand(@a)];
	$b =~ s/^\S+\[\d+\/\d+\]: //;
	$b = $self->parse_strvariables($channel, $nick, $cmdargs, $b);

	foreach my $l (split(/\x02THEN\s/, $b)) {
	    my $do_me = ($l =~ m/^\x02ACT\s/) ? 1 : 0;
	    $l =~ s/^\x02ACT\s//;
	    if ($do_me) {
		$self->botaction($l, $output);
		$retval = 1;
	    } else {
		$self->botspeak($l, $output);
		$retval = 1;
	    }
	}
    }
    return $retval;
}


# Commands for public
sub pub_msg {
    my ( $self, $channel, $nick, $msg ) = @_;

    my $nickmatch = 0;

    # remove our nick from the beginning of the line.
    if ($msg !~ /^$self->{'Nick'}\?$/i) {
	if ($msg =~ m/^\Q$self->{'Nick'}\E\s*[:,]?\s*(.*)$/i) {
	    $msg = $1;
	    $nickmatch = 1;
	}
    }

    if ($msg =~ m/^!learn\s+edit\s+(\S+)\s+(\d*\s*)s\s*(.*)$/i) {
# !learn edit foo[N] s/bar/baz/
# !learn edit foo N s/bar/baz/
	my $term = $1;
	my $tnum = $2 || 0;
	my ($edita, $editb, $opts);

	if (!can_edit_learndb($nick, $term)) {
	    $self->botspeak("You can't do that.", $nick);
	    return;
	}

	if (($edita, $editb, $opts) = grok_learn_edit_regex($3)) {
	    $self->do_pubcmd_dbedit($channel,$term,$tnum,$edita,$editb,$opts);
	} elsif ($@) {
	    $self->botspeak($@, $channel);
	}
    }
    elsif ($msg =~ m/^!learn\s+del\s+(\S+) *(\d?\d?)$/i) {
# !learn del foo
# !learn del foo N
# !learn del foo[N]
	my $term = $1;
	my $num = $2;
	if (!can_edit_learndb($nick, $term)) {
	    $self->botspeak("You can't do that.", $nick);
	    return;
	}
	$self->do_pubcmd_dbdelete($channel, $term, $num);
    }
    elsif ($msg =~ m/^!learn\s+swap\s+(\S+)\s+(\S+)$/i) {
# !learn swap foo[N] bar[M]
	my $terma = $1;
	my $termb = $2;
	if (!can_edit_learndb($nick, $terma) || !can_edit_learndb($nick, $termb)) {
	    $self->botspeak("You can't do that.", $nick);
	    return;
	}
	$self->do_pubcmd_dbswap($channel, $terma, $termb);
    }
    elsif ($msg =~ m/^!learn\s+add\s+(\S+)\s+(.+)$/i) {
# !learn add foo bar
	my $term = $1;
	my $def = $2;
	if (!can_edit_learndb($nick, $term)) {
	    $self->botspeak("You can't do that.", $nick);
	    return;
	}
	$self->do_pubcmd_dbadd($channel, $nick, $term, $def);
    } elsif (($self->priv_and_pub_msg($channel, $nick, $msg) == 1) &&
	     ($msg =~ m/^\s*(\S.+)$/i)) {
	my $trigmsg = $1;
	if (!($self->handle_learndb_trigger($channel, $nick, $trigmsg))) {
	    $trigmsg = $self->mangle_msg_for_trigger($trigmsg);
	    $trigmsg = "\$self_".$trigmsg if ($nickmatch);
	    $self->handle_learndb_trigger($channel, $nick, $trigmsg);
	}

    }
}



# Handle public events
sub on_public {

    my ( $self, $who, $where, $msg ) = @_[ OBJECT, ARG0 .. $#_ ];
    my $nick = ( split /!/, $who )[0];
    my $channel = $where->[0];
    my $pubmsg  = $msg;
#    debugprint("[$channel] <$nick> $msg");

    my $seennick = $nick;
    $seennick =~ tr/A-Z/a-z/;
    $seen_db->seen_log($seennick, "said \"$msg\"");

    $self->log_channel_msg($channel, $nick, $msg);

    return if (grep {$_ eq lc($channel)} $self->{'ignored_channels'});

    recent_nicks_add($nick);

    $self->check_messages($nick, $channel);

    if ($ignorance->is_ignored($who, $msg)) {
	$self->bot_priv_msg("[ignored] <$nick> $msg");
	return;
    }

    $self->pub_msg($channel, $nick, $msg);
}

sub handle_querythread_output {
    my ( $self ) = $_[ OBJECT ];

    {
	lock(@querythread_output);
	if (scalar(@querythread_output)) {
	    my $str = pop(@querythread_output);
	    my ($channel,$nick,$query) = split(/\t/, $str);
	    $self->botspeak("$nick: $query", $channel);
	}
    }
    $kernel->delay('handle_querythread_out' => 10);
}

sub handle_reddit_rss {
    my ( $self ) = $_[ OBJECT ];

    my $s = $reddit_rss->update_rss();
    $self->botspeak($s) if ($s);

    $kernel->delay('handle_reddit_rss_data' => 30);
}

my $privmsg_time = 0;
my $privmsg_throttle = 10;

sub can_do_privmsg_cmd {
    my $return = 1;

    $return = 0 if (time() < ($privmsg_time + $privmsg_throttle));
    $privmsg_time = time();
    return $return;
}


my $parsestr_cmd_args = "";

# admin commands
sub admin_msg {
    my ( $self, $who, $nicks, $msg ) = @_;

    my $nick = ( split /!/, $who )[0];

	if ($msg =~ m/^!say\s(\S+)\s(.+)$/i) {
	    my $chn = $1;
	    my $sayeth = $2;
	    $self->botspeak($sayeth, $chn);
	}
	elsif ($msg =~ m/^!wiki/) {
	    my $ngrams = scalar (@wiki_datagram_queue);
	    $self->botspeak("Wiki recentchanges queue: $ngrams", $nick);
	}
	elsif ($msg =~ m/^!ignore\s(\S+ +\S.*)$/i) {
	    my $ign = $1;
	    $ign =~ s/ /\t/;
	    my @ignik = (split /\t/, $ign);
	    $ignorance->add($ign);
	    $self->botspeak("Now ignoring: user '".$ignik[0]."' saying '".$ignik[1]."'", $nick);
	}
	elsif ($msg =~ m/^!ignore$/i) {
	    my $a;
	    my $count = scalar($ignorance->count());
	    if ($count > 0) {
		for (my $cnt = 0; $cnt < $count; $cnt++) {
		    $a = $ignorance->get_nth($cnt);
		    my @ign = split( /\t/, $a);
		    $self->botspeak($cnt.": user '".$ign[0]."' saying '".$ign[1]."'", $nick);
		}
	    } else {
		    $self->botspeak("Nothing is ignored", $nick);
	    }
	}
	elsif ($msg =~ m/^!shorten\s+(\S+)$/i) {
	    my $urli = $1;
	    $self->botspeak(shorten_url($urli), $nick);
	}
	elsif ($msg =~ m/^!togglebuglist\s*$/i) {
	    if ($self->{'CheckBug'} > 0) {
		$self->{'CheckBug'} = 0;
		$self->botspeak("Buglist checking disabled.", $nick);
	    } else {
		$self->{'CheckBug'} = 1;
		$kernel->delay('buglist_update' => 30);
		$self->botspeak("Buglist checking enabled.", $nick);
	    }
	}
	elsif ($msg =~ m/^!togglelogfile\s*$/i) {
	    if ($self->{'CheckLog'} > 0) {
		$self->{'CheckLog'} = 0;
		$self->botspeak("Logfile checking disabled.", $nick);
	    } else {
		$self->{'CheckLog'} = 1;
		$kernel->delay('d_tick' => 10);
		$self->botspeak("Logfile checking enabled.", $nick);
	    }
	}
	elsif ($msg =~ m/^!rmignore\s(\d+)$/i) {
	    my $ign = $1;
	    if ($ign >= 0 && $ign < $ignorance->count()) {
		my @a = split(/\t/, $ignorance->get_nth($ign));
		$self->botspeak("De-ignoring: user '".$a[0]."' saying '".$a[1]."'", $nick);
		$ignorance->rm_nth($ign);
	    } else {
		$self->botspeak("No such ignorance.", $nick);
	    }
	}
#	elsif ($msg =~ m/^!msg\s(.+)\s(.+)$/i) {
#	    my $tonick = $1;
#	    my $sayeth = $2;
#	    $irc->yield('privmsg', $tonick, $sayeth);
#	}
	elsif ($msg =~ m/^!nick\s(.+)$/i) {
	    my $newnik = $1;
	    $irc->yield('nick', "$newnik");
	}
	elsif ($msg =~ m/^!join\s(\S+)$/i) {
	    my $chn = $1;
	    if (defined $chn && ($chn =~ m/^#/) && (!( grep {$_ eq $chn } @{$self->{'joined_channels'}} ))) {
		$irc->yield('join', $chn);
	    } else {
		$self->botspeak("Sorry.", $nick);
	    }
	}
	elsif ($msg =~ m/^!(leave|part)\s(\S+)$/i) {
	    my $chn = $2;
	    if (defined $chn && ($chn =~ m/^#/) && (( grep {$_ eq $chn } @{$self->{'joined_channels'}} ))) {
		my $tmpa;
		my $tmpcounter = 0;
		foreach $tmpa (@{$self->{'joined_channels'}}) {
		    if ($tmpa eq $chn) {
			splice(@{$self->{'joined_channels'}}, $tmpcounter, 1);
			last;
		    }
		    $tmpcounter++;
		}
		$irc->yield('part', $chn);
	    } else {
		$self->botspeak("Sorry.", $nick);
	    }
	}
	elsif ($msg =~ m/^!me\s(\S+)\s(.+)/i) {
	    my $chn = $1;
	    my $message = $2;
	    if (defined $chn && ($chn =~ m/^#/) && ( grep {$_ eq $chn } @{$self->{'joined_channels'}} )) {
		$self->botaction($message, $chn);
	    } else {
		$self->botspeak("Sorry, $chn is not a channel i'm on.", $nick);
	    }
	}
	elsif ($msg =~ m/^!privme\s(\S+)\s(.+)/i) {
	    my $target = $1;
	    my $message = $2;
	    $self->botaction($message, $target);
	}
	elsif ($msg =~ m/^!throttle$/i) {
	    $self->botspeak("Throttle,  priv: $privmsg_throttle, pub: $pubmsg_throttle", $nick);
	}
	elsif ($msg =~ m/^!bones$/i) {
	    my $bonefiledir = $self->{'NHLvlFiles'};
	    $bonefiledir =~ s/\/$//;
	    my @bonefiles = `ls -al $bonefiledir/bon* | nl`;
	    my $a;
	    if (@bonefiles > 0) {
	    	foreach $a (@bonefiles) {
		    $a =~ s/$bonefiledir\///;
		    $a =~ s/\t//g;
		    $self->botspeak($a, $nick);
	     	}
	    } else {
		$self->botspeak("No bones.", $nick);
	    }
	}
	elsif ($msg =~ m/^!throttle\s(\d+)\s(\d+)$/i) {
	    $privmsg_throttle = $1;
	    $pubmsg_throttle = $2;
	    $self->botspeak("Throttle,  priv: $privmsg_throttle, pub: $pubmsg_throttle", $nick);
	}
	elsif ($msg =~ m/^!deid$/i) {
	    $admin_nicks->nick_deidentify($nick);
	    if ((defined $send_msg_id) && ($send_msg_id eq $nick)) {
		undef $send_msg_id;
	    }
	    $self->botspeak("De-identified. Bye.", $nick);
	}
	elsif ($msg =~ m/^!id$/i) {
	    $self->botspeak("Identified nicks: ". $admin_nicks->get_identified_nicks(), $nick);
	}
	elsif ($msg =~ m/^!parsestr\s(.+)$/) {
	    my $b = $self->parse_strvariables($nick, $nick, $parsestr_cmd_args, $1);
	    $self->botspeak("parsed as: \"".$b."\"", $nick);
	}
	elsif ($msg =~ m/^!parseargs(.*)?$/) {
	    $parsestr_cmd_args = paramstr_trim($1) if ($1);
	    $self->botspeak("command arguments for !parsestr: \"".$parsestr_cmd_args."\"", $nick);
	}
	elsif ($msg =~ m/^!trigger\s+(\S+)\s+(\S.*)$/) {
	    my $chn = $1;
	    my $args = $2;
	    $self->handle_learndb_trigger($chn, $nick, $args, $nick);
	}
	elsif ($msg =~ m/^!showmsg$/i) {
	    if ((defined $send_msg_id) && ($send_msg_id eq $nick)) {
		$self->botspeak("Not showing bot privmsgs anymore.", $nick);
		undef $send_msg_id;
	    } else {
		if (defined $send_msg_id) {
		    $self->botspeak("Showing privmsgs to $nick now, sorry.", $send_msg_id);
		    $self->botspeak("Privmsgs were shown to $send_msg_id.", $nick);
		}
		$send_msg_id = $nick;
		$self->botspeak("Showing privmsgs to you.", $nick);
	    }
	}
	elsif ($msg =~ m/^!die(\s.+)?$/i) {
	    $self->botspeak(paramstr_trim($1)) if ($1);
	    kill_bot();
	}
	elsif ($msg =~ m/^!help$/i) {
	    $self->botspeak("Command help: " . $self->{'admin_help_url'}, $nick);
	} else {
	    $self->pub_msg($nick, $nick, $msg);
	}
}

# Handle privmsg communication.
sub on_msg {

    my ( $self, $who, $nicks, $msg ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];
    my $nick = ( split /!/, $who )[0];

    debugprint("[$self->{'Nick'}] <$nick> $msg");

    $nick =~ tr/A-Z/a-z/;

    $self->check_messages($nick, $nick);

    return if ($ignorance->is_ignored($who, $msg));

    $self->bot_priv_msg("<$nick> $msg") if ((defined $send_msg_id) && ($send_msg_id ne $nick));

    if ($msg =~ m/^!decode\s(.+)$/i) {
# !decode <recordline>
	my $line = $1;
	$self->botspeak(demunge_recordline($line, 9), $nick);
    }
    elsif ($self->priv_and_pub_msg($nick, $nick, $msg) == 0) {
#	handled in priv_and_pub_msg
    }
    elsif ($msg =~ m/^!id\s(.*)$/i) {
# !id <password>
	my $pw = $1;
	if (!$admin_nicks->is_identified($nick)) {
	    if ($pw eq $self->{'Apass'}) {
		$admin_nicks->nick_identify($nick);
		$self->botspeak("Hello, $nick", $nick);
		if (!(defined $send_msg_id)) {
		    $self->botspeak("Sending bot privmsgs to you.", $nick);
		    $send_msg_id = $nick;
		} else {
		    $self->botspeak("Bot privmsgs are sent to $send_msg_id.", $nick);
		}
	    }
	}
    }
    elsif ($admin_nicks->is_identified($nick)) {
	$self->admin_msg($who, $nicks, $msg);
    }
}

# Handle dcc request, accept and move on.
sub on_dcc_req {
    my ( $self, $type, $who, $id ) = @_[ OBJECT, ARG0, ARG1, ARG3 ];
    $irc->yield('dcc_accept', $id);
}

# Start up the DCC session, or welcome back
sub on_dcc_start {
    my ( $self, $id, $who, $type ) = @_[ OBJECT, ARG0, ARG1, ARG2 ];
    my $nick = ( split /!/, $who )[0];
    if ( $type eq 'CHAT' ) {
	$self->bot_priv_msg("DCC CHAT from $nick");
    }
}


# Handle a dcc_chat session, parse for commands
sub on_dcc_chat {
    my ( $self, $id, $who, $msg ) = @_[ OBJECT, ARG0, ARG1, ARG3 ];
    my $nick = ( split /!/, $who )[0];
    $self->bot_priv_msg("DCC CHAT <$nick> $msg");
}

# Got an error, attempt to close session.
# Doesn't appear to be working, I need to question
# my implementation, but we'll do that later
sub on_dcc_err {
    my ( $self, $id, $who ) = @_[ OBJECT, ARG0, ARG2 ];
    my $nick = ( split /!/, $who )[0];
    $self->bot_priv_msg("DCC CHAT ERR ($nick)");
}

# DCC session is done, close out, kill session.
sub on_dcc_done {
    my ( $self, $id, $who ) = @_[ OBJECT, ARG0, ARG1 ];
    my $nick = ( split /!/, $who )[0];

    $self->bot_priv_msg("DCC CHAT CLOSED ($nick)");
}

sub on_wiki_datagram {
    my ( $self, $socket ) = @_[ OBJECT, ARG0 ];
    recv( $socket, my $message = "", DATAGRAM_MAXLEN, 0 );
    if ($message ne "") {
	push @wiki_datagram_queue, { "time" => time(), "message" => $message };
    }
}

sub mangle_wiki_datagram_msg {
    my $message = shift || "";

    $message =~ s/\003\d\d?//g; # Stupid MW outputs goddamned color codes.
    $message =~ s/\003//g;

    if ($message =~ m/^(.*) (https?:\/\/\S+) (.+)$/i) {
        my $preu = $1;
        my $url = $2;
        my $postu = $3;
        if ($preu =~ m/]]\s(\S*)$/) {
            return "" if ($1 =~ m/B/); # bot edit
        }
        $message = $preu." ".shorten_url($url)." ".$postu;
    }
    return $message;
}

sub handle_wiki_datagrams {
    my ( $self ) = $_[ OBJECT ];

    my $chn = $self->channel_for_action('wiki_report');
    my $message;

    $kernel->delay('handle_wiki_data' => 10);

    my $ngrams = scalar(@wiki_datagram_queue);
    my $data;

    if ($ngrams > 0) {
        $data = pop(@wiki_datagram_queue);
        $message = mangle_wiki_datagram_msg($data->{"message"});
	return if ($message =~ m/^..Special.Log.patrol/);
        if ($ngrams > 1) {
            $self->botspeak("$ngrams changes, newest is: $message", $chn) if ($message ne "");
            @wiki_datagram_queue = ();
        } elsif ($ngrams > 0) {
            $self->botspeak("$message", $chn) if ($message ne "");
        }
    }
}


# Got back info from the NAMES command.
sub on_names {
    my ( $self, $sender, $server, $who ) = @_[ OBJECT, SENDER, ARG0 .. ARG1 ];

    $who =~ /([^"]*)\s+:([^"]*)\s+/;
    my $chan  = $1;
    my $names = $2;
    $names =~ tr/A-Z/a-z/;
    $seen_db->seen_setnicks($names, $chan);
}

$SIG{'INT'} = \&kill_bot;
$SIG{'HUP'} = \&kill_bot;

sub kill_bot {

    $reddit_rss->cache_write();
    $buglist_db->cache_write();
    database_sync();
    $seen_db->sync();
    log_channel_msg_flush();
    $ignorance->save();
    die("kill_bot()");
}

# Daemonize
sub daemonize {
    my $self = shift;
    my $path;
    $self->{'LogPath'} eq 'null' ? $path=$ENV{'HOME'} : $path=$self->{'LogPath'};
    chdir '/'                  or die "Can't chdir to /: $!";
    open STDIN, '/dev/null'    or die "Can't read /dev/null: $!";
    open STDOUT, ">$path/bot.log" or die "Can't write to bot log: $!";
    open STDERR, ">$path/error.log" or die "Can't write to error log: $!";
    defined(my $pid = fork)    or die "Can't fork: $!";
    exit if $pid;
    setsid                     or die "Can't start a new session: $!";
    umask 0;
}


# Disconnected, clean up a bit
sub on_disco {

    my $self = shift;
#    my ($self) = $_[ OBJECT ];

#    $kernel->delay('keepalive' => undef);
#    $kernel->delay('d_tick' => undef);

    $reddit_rss->cache_write();
    $buglist_db->cache_write();
    database_sync();
    $seen_db->sync();
    log_channel_msg_flush();
    $ignorance->save();

    exit(0);

}

1;

__END__
