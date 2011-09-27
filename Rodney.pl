#!/usr/bin/perl
use strict;

do "Rodney.pm";

my $chrootpath  = '/opt/nethack/nethack.alt.org';
my $pub_url     = 'http://alt.org/nethack';
my $botdatapath = '/opt/nethack/rodney';

  # Initialize new object
  my $bot = Rodney->new( Debug    => 0,
			 Nick     => 'Rodney',
			 AltNick  => 'Yendor',
			 Nickpass => '**CHANGE ME**',  # nick password
			 Server   => 'irc.freenode.net',
			 Pass     => '',
			 Port     => '6667',
			 Username => 'rodney',
			 Ircname  => 'Rodney',
			 Admin    => 'paxed',
			 Apass    => '**CHANGE ME**',  # admin password
			 Channels => [ '#nethack', '#nethackwiki' ],

			 actions => {
			     wiki_report => { channel => "#nethackwiki" }
			 },

# channels the bot is currently joined in
			 joined_channels => [],
# channels to ignore (for triggers & commands)
			 ignored_channels => [],

			 LogPath  => $botdatapath.'/log/',
			 LearnDBFile => $botdatapath.'/data/learn.dat',
#			 SeenDBFile => $botdatapath.'/data/seen.dat',
			 SeenDBFile => $botdatapath.'/data/seen.db',
			 MessagesDBFile => $botdatapath.'/data/messages.db',
			 NHLvlFiles => $chrootpath.'/nh343/var/',
			 WhereIsDir => $chrootpath.'/nh343/var/whereis/',
			 Daemonize => 1, # Daemonize the process
			 CheckLog => 1,  # Monitor logfile
			 Version  => 'Version is meaningless.',
			 SpeakLimit => 2,      # prevent ?> flooding
			 PublicScorePath => $pub_url.'/player.php?player=',

			 CheckBug => 1,  # Monitor bugpage
			 BugCache => $botdatapath.'/data/bugcache.txt',
			 nh_org_bugpage => 'http://nethack.org/v343/bugs.html',

			 twitteruserpass => '**CHANGE ME**', # username:password
			 twitteruserpass_asc => '**CHANGE ME**', # username:password
			 use_twitter => 0,

			 admin_help_url => $pub_url.'/Rodney/admin_commands.txt',

			 dglInprogPath => $chrootpath.'/dgldir/inprogress-nh343',
			 PublicDumpPath => $pub_url.'/dumplog',
			 NHDumpPath => $chrootpath.'/dgldir/dumplog',
			 PublicRCPath => $pub_url.'/rcfiles',
			 NHRCPath => $chrootpath.'/dgldir/rcfiles',
			 nh_logfile => $chrootpath.'/nh343/var/xlogfile',

			 nh_logfile_db => $chrootpath.'/nh343/var/xlogfile.db',

			 xlogfiledb => {
			     dbtype => 'mysql',
			     db => 'xlogfiledb',
			     user => 'CHANGEME',
			     pass => 'CHANGEME'
			 },
			 shorturldb => {
			     dbtype => 'mysql',
			     db => 'shorturlnaodb',
			     user => 'CHANGEME',
			     pass => 'CHANGEME'
			 },
			 dgldb => {
			     dbtype => 'SQLite',
			     db => $chrootpath.'/dgldir/dgamelaunch.db'
			 },

			 nh_monsters_file => $botdatapath.'/data/nh343monsters.txt',
			 nh_objects_file => $botdatapath.'/data/nh343objects.txt',
			 learn_url => $pub_url.'/Rodney/rodney-learn.php?s=',
			 userdata_name => $chrootpath.'/dgldir/userdata/',
			 userdata_dumpname_puburl => $pub_url.'/userdata/%u/dumplog/',
			 userdata_ttyrec => $chrootpath.'/dgldir/userdata/%U/%u/ttyrec/%T.ttyrec',
			 userdata_ttyrec_puburl => $pub_url.'/userdata/%u/ttyrec/%T.ttyrec',
			 nh_savefiledir => $chrootpath.'/nh343/var/save/',
			 userdata_rcfile_puburl => $pub_url.'/userdata/%u/%u.nh343rc',

			 nh_livelogfile => $chrootpath.'/nh343/var/livelog',
			 NHRecordFile => $chrootpath.'/nh343/var/record',
			 nh_dumppath => $chrootpath.'/dgldir/userdata/%U/%u/dumplog/%t.nh343.txt',
			 nh_dumpurl  => $pub_url.'/userdata/%u/dumplog/%t.nh343.txt'
    );

  # Run the bot
  $bot->run();
