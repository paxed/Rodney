#!/usr/bin/perl
use strict;

use Rodney;

my $chrootpath  = '/opt/nethack/nethack.alt.org';
my $pub_url     = 'https://alt.org/nethack';
my $pub_ttyrec_archive = 'https://s3.amazonaws.com/altorg/ttyrec';
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

			 RSS_tstamp => $botdatapath.'/data/',
			 LogPath  => $botdatapath.'/log/',
			 LearnDBFile => $botdatapath.'/data/learn.dat',
#			 SeenDBFile => $botdatapath.'/data/seen.dat',
			 SeenDBFile => $botdatapath.'/data/seen.db',
			 MessagesDBFile => $botdatapath.'/data/messages.db',
			 Daemonize => 1, # Daemonize the process
			 CheckLog => 1,  # Monitor logfile
			 Version  => 'Version is meaningless.',
			 SpeakLimit => 2,      # prevent ?> flooding
			 PublicScorePath => $pub_url.'/player.php?player=',

			 CheckBug => 0,  # Monitor bugpage
			 BugCache => $botdatapath.'/data/bugcache.txt',

			 twitteruserpass => '**CHANGE ME**', # username:password
			 twitteruserpass_asc => '**CHANGE ME**', # username:password
			 use_twitter => 0,

			 admin_help_url => $pub_url.'/Rodney/admin_commands.txt',

			 PublicDumpPath => $pub_url.'/dumplog',
			 NHDumpPath => $chrootpath.'/dgldir/dumplog',
			 PublicRCPath => $pub_url.'/rcfiles',
			 NHRCPath => $chrootpath.'/dgldir/rcfiles',

			 xlogfiledb => {
			     host => 'localhost',
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
			 nethackwikidb => {
			     host => 'localhost',
			     dbtype => 'mysql',
			     db => 'nethackwikidb',
			     user => 'CHANGEME',
			     pass => 'CHANGEME'
			 },
			 dgldb => {
			     dbtype => 'SQLite',
			     db => $chrootpath.'/dgldir/dgamelaunch.db'
			 },

			 ignorancefile => $botdatapath.'/data/ignored.txt',
			 learn_url => $pub_url.'/Rodney/rodney-learn.php?s=',
			 userdata_name => $chrootpath.'/dgldir/userdata/',
			 userdata_dumpname_puburl => $pub_url.'/userdata/%u/dumplog/',
			 userdata_ttyrec => $chrootpath.'/dgldir/userdata/%U/%u/ttyrec/%T.ttyrec',
			 userdata_ttyrec_puburl => $pub_url.'/userdata/%u/ttyrec/%T.ttyrec',

                         gamedata_default_version => 'nh360',
                         gamedata => {
                             'nh343' => {
                                 CheckLog => 0,  # Monitor logfile for this game
                                 NHLvlFiles => $chrootpath.'/nh343/var/',
                                 WhereIsDir => $chrootpath.'/nh343/var/whereis/',
                                 nh_org_bugpage => 'http://nethack.org/v343/bugs.html',
                                 dglInprogPath => $chrootpath.'/dgldir/inprogress-nh343',
                                 nh_logfile => $chrootpath.'/nh343/var/xlogfile',
                                 nh_monsters_file => $botdatapath.'/data/nh343monsters.txt',
                                 nh_objects_file => $botdatapath.'/data/nh343objects.txt',
                                 nh_savefiledir => $chrootpath.'/nh343/var/save/',
                                 userdata_rcfile_puburl => $pub_url.'/userdata/%u/%u.nh343rc',
                                 nh_livelogfile => $chrootpath.'/nh343/var/livelog',
                                 NHRecordFile => $chrootpath.'/nh343/var/record',
                                 nh_dumppath => $chrootpath.'/dgldir/userdata/%U/%u/dumplog/%t.nh343.txt',
                                 nh_dumpurl  => $pub_url.'/userdata/%u/dumplog/%t.nh343.txt',
                             },
                             'nh360' => {
                                 CheckLog => 1,  # Monitor logfile for this game
                                 NHLvlFiles => $chrootpath.'/nh360/var/',
                                 WhereIsDir => $chrootpath.'/nh360/var/whereis/',
                                 nh_org_bugpage => 'http://nethack.org/v360/bugs.html',
                                 dglInprogPath => $chrootpath.'/dgldir/inprogress-nh360',
                                 nh_logfile => $chrootpath.'/nh360/var/xlogfile',
                                 nh_monsters_file => $botdatapath.'/data/nh360monsters.txt',
                                 nh_objects_file => $botdatapath.'/data/nh360objects.txt',
                                 nh_savefiledir => $chrootpath.'/nh360/var/save/',
                                 userdata_rcfile_puburl => $pub_url.'/userdata/%u/%u.nh360rc',
                                 nh_livelogfile => $chrootpath.'/nh360/var/livelog',
                                 NHRecordFile => $chrootpath.'/nh360/var/record',
                                 nh_dumppath => $chrootpath.'/dgldir/userdata/%U/%u/dumplog/%t.nh360.txt',
                                 nh_dumpurl  => $pub_url.'/userdata/%u/dumplog/%t.nh360.txt',
                             },
                             'nh361dev' => {
                                 CheckLog => 1,  # Monitor logfile for this game
                                 NHLvlFiles => $chrootpath.'/nh361dev.20170926-1/var/',
                                 WhereIsDir => $chrootpath.'/nh361dev.20170926-1/var/whereis/',
                                 nh_org_bugpage => 'http://nethack.org/v360/bugs.html',
                                 dglInprogPath => $chrootpath.'/dgldir/inprogress-nh361dev.20170926',
                                 nh_logfile => $chrootpath.'/nh361dev.common/xlogfile',
                                 nh_monsters_file => $botdatapath.'/data/nh360monsters.txt',
                                 nh_objects_file => $botdatapath.'/data/nh360objects.txt',
                                 nh_savefiledir => $chrootpath.'/nh361dev.20170926-1/var/save/',
                                 userdata_rcfile_puburl => $pub_url.'/userdata/%u/%u.nh361rc',
                                 nh_livelogfile => $chrootpath.'/nh361dev.common/livelog',
                                 NHRecordFile => $chrootpath.'/nh361dev.common/record',
                                 nh_dumppath => $chrootpath.'/dgldir/userdata/%U/%u/dumplog/%t.nh361dev.txt',
                                 nh_dumpurl  => $pub_url.'/userdata/%u/dumplog/%t.nh361dev.txt',
                             }
                         }

    );

  # Run the bot
  $bot->run();
