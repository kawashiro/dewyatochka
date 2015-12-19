#!/usr/bin/perl
#################################################################
#  spicytrivia.pl
#  by Daniel Wedul (daniel@wedul.com)
#  Created on: June 3, 2005
#  Last Modified: Aug 15, 2008
#*****************************
#  This is a trivia bot program for jabber.
#  It will log itself in, ask questions and keep track of scores.
#  for more information view the README
#*****************************
#  Partially rewritten by Nitorek so this is Dewyatochka now ^-^
#  Jan, 2014
#################################################################

use strict;
use utf8;

if ($^O =~ m/^mswin/i) {
	eval { "use open ':std', ':encoding(cp866)';" }
} else {
	eval { "use open ':std', ':encoding(UTF-8)';" }
}


##################################################
###################### Setup #####################
##################################################

# include the Jabber stuff
use Net::Jabber;
# include other modules needed
use Cwd 'abs_path';
use File::Basename;
use LWP::Simple;
use XML::Parser;
use URI::Escape;
use HTML::Entities;
use JSON;
#use Data::Dumper;
use Digest::MD5 qw(md5);

#This is the filename that contains the setup information
my $ConfigFile = dirname(abs_path($0)) . "/setup.ini";

if ($#ARGV >= 0) {
	$ConfigFile = join(" ", @ARGV);
}

#set showXMLin to have it print all XML that it sees.
my $showXMLin = 0;

#force the stop sub to run no matter what, when the program is stopped
$SIG{HUP} = \&Stop;
$SIG{KILL} = \&Stop;
$SIG{TERM} = \&Stop;
$SIG{INT} = \&Stop;

#create a config hash
my %setup = ();

#open the config file and get the settings
open(CONF, '< :encoding(UTF-8)', $ConfigFile) or die "Could not open $ConfigFile for input\n";
while(<CONF>) {
	my $in = $_;
	chomp $in;
	if ($in =~ m/^[a-z0-9_\-]+=[^=]*/i) {
		my @l = split(/=/, $in);
		chomp(@l[0]);
		chomp(@l[1]);
		$setup{uc(@l[0])} = @l[1];
	}
}
#close the config file
close(CONF);

my @roomServer = split(/@/, $setup{ROOM});
my $room = $roomServer[0];

#make sure the config file contains everything needed
if (!defined($setup{USERNAME}) or
	!defined($setup{PASSWORD}) or
	!defined($setup{SERVER}) or
	!defined($setup{ROOM}) or
	!defined($setup{OWNER}) or
	!defined($setup{ADMIN})
) {
	print "The setup file $ConfigFile is invalid.\n";
	exit(1);
}

#get the administrators' usernames
my @administrators = ($setup{"ADMIN"});
foreach my $i (2..9) {
	my $key = "ADMIN" . $i;
	if (defined($setup{$key})) {
		push(@administrators, $setup{$key});
	}
}

##################################################
############### End of Setup #####################
##################################################

# create global variables that communicate messages
my $TheUser = "";
my $TheMess = "";
my $mode = 'chat'; # chat|console
my $Connection = undef;
# Krolek's bot messages counter
my $DogCounter = 0;
# Anime titles
my %titles = ();
# Cool stories
my @coolStories = ();
# mail.ru questions
my @questions = ();
# Global crap for XML-parser
my $currentTitleId = 0;
my $currentTitleTitle = '';
my $currentTitleScore = 0;
my $readThisTitle = 0;
my $element = '';
# Last message recieved time
my $lastinput = time;
# Messages counters
my $recievedCnt = 0;
my $processedCnt = 0;
my $consoleCommandCnt = 0;
my $consoleSuccessCnt = 0;
my $consoleErrorCnt = 0;

# Console commands handlers:
my %consoleHandlers = (
	'login' => \&Auth,
);
my @adminSessions = ();

############################################################
############  XML parser callbacks follow here  ############
############################################################

########################################################################
#
#  Callback for XML start element
#
########################################################################
sub StartElement
{
	my($parser, $_element, %attrs) = @_;
	$element = $_element;
	if ($element eq 'anime') {
		$currentTitleId = $attrs{aid};
	} elsif ($element eq 'title') {
		my $score = 0;

		if ($attrs{type} eq 'main') {
			$score = 1;
		} elsif ($attrs{type} eq 'official' && $attrs{lang} eq 'ru') {
			$score = 3;
		} elsif ($attrs{type} eq 'syn' && $attrs{lang} eq 'ru') {
			$score = 2;
		}
		if ($score > $currentTitleScore) {
			$readThisTitle = 1;
			$currentTitleScore = $score;
		} else {
			$readThisTitle = 0;
		}
	}
}

########################################################################
#
#  Callback for XML character data
#
########################################################################
sub CharacterData
{
	my($parser, $data) = @_;
	if ($readThisTitle && length($data) > 2) { # FUCK!
		$currentTitleTitle = $data;
	}
}

########################################################################
#
#  Callback for XML End element
#
########################################################################
sub EndElement
{
	my($parser, $_element) = @_;
	if ($_element eq 'anime') {
		print "\rLoading anime title #" . $currentTitleId . " ... ";
		$currentTitleScore = 0;
		if ($currentTitleId >= 6000) { # TODO: Remove this crappy hack or migrate to a normal API
			$titles{$currentTitleId} = $currentTitleTitle;
		}
	}
}
############################################################
#################  End of XML parser crap  #################
############################################################

########################################################################
#
#  Load all anime titles from XML
#
#  usage: &LoadTitles;
#
########################################################################
sub LoadTitles
{
	if (defined($setup{ANIDB_XML})) {
		my $parser = new XML::Parser();
		$parser->setHandlers(Start => \&StartElement, Char => \&CharacterData, End => \&EndElement);
		$parser->parsefile($setup{ANIDB_XML});
		print "Done!\n"
	}
}


#################################################
#################  main program  ################
#################################################

&LoadTitles;
if (&LoginScript) {
	&ConnectedLoop;
	&Stop;
}

#################################################
########### End of main program  ################
#################################################


########################################################################
#
#  Connected Loop - This is the loop that waits for a start command
#                   from a user
#  usage: &ConnectedLoop;
#  TODO: Move time-related settings to the config
#
########################################################################
sub ConnectedLoop
{
	while(1) {
		print "\rRecieved messages: $recievedCnt; console commands: $consoleCommandCnt; processed: $processedCnt; failed (console): $consoleErrorCnt";
		#wait for an input and react if it should
		$TheMess = "";
		$TheUser = "";
		my $success = $Connection->Process(60);
		if ($success) {
			$recievedCnt++;
			if ($mode eq 'chat') {
				$processedCnt += &CheckForCommand;
			} elsif ($mode eq 'console' && $TheMess) {
				$consoleCommandCnt++;
				$processedCnt++;
				$consoleSuccessCnt += &CheckForConsoleCommand;
				$consoleErrorCnt = $consoleCommandCnt - $consoleSuccessCnt;
			}
		} elsif (defined($success)) {
			# Action on idle
			if ($lastinput < time - 10800) {
				&MrQuestion;
				$lastinput = time;
			}
		} else {
			do {
				print "\nConnection died, trying to reconnect...\n";
				sleep(5);
			} while (!&LoginScript)
		}
	}
}

########################################################################
#
#  LoginScript - This will use $LoginFile to log a user into a
#                group chat room
#  usage: &LoginScript($LoginFile);
#
########################################################################
sub LoginScript
{
	print "Connecting to the server ... ";
	$Connection = new Net::Jabber::Client();
	#get the setup information
	my $server = $setup{"SERVER"};
	my $port = "5222";
	if (defined($setup{"PORT"})) { $port = $setup{"PORT"}; }
	my $username = $setup{"USERNAME"};
	my $password = $setup{"PASSWORD"};
	my $resource = "Deewyatochka";
	my $nick = $username;
	if (defined($setup{"NICK"})) {
		$nick = $setup{"NICK"};
	} else {
		$setup{"NICK"} = $username;
	}
	$setup{FULLID} = $username . "\@" . $server . "/" . $resource;

	#Set the method to be called when receiving a message
	$Connection->SetCallBacks(message => \&InMessage);

	#Connect to the server
	my $status = $Connection->Connect(hostname => $server,
	                                  port => $port,
	                                  tls => 1);

	if ( !(defined($status)) || !($status) ) {
		print "ERROR: $!\n";
		return 0;
	}

	#Log In
	my @result = $Connection->AuthSend(username => $username,
	                                   password => $password,
	                                   resource => $resource);
	if ($result[0] ne "ok") {
		print "ERROR: Authorization failed: $result[0] - $result[1]\n";
		return 0;
	}

	#Get the roster to let everyone know it's on!
	$Connection->RosterGet();
	$Connection->PresenceSend();

	print "Done!\nEntering the room ... ";
	#Enter the trivia room
	$Connection->PresenceSend(from => $setup{FULLID},
	                          to => $setup{ROOM} . "/" . $setup{NICK});
	#We are now logged in and in the room
	print "Done!\n";
	return 1;
}

########################################################################
#
#  Stop - Makes sure the trivia bot is disconnected before quiting
#  usage: &Stop;
#
########################################################################
sub Stop
{
	$Connection->Disconnect();
	exit(0);
}


########################################################################
#
#  InMessage - This subroutine should be automatically called when
#              the connection receives a message.
#  usage: $Connection->SetCallbacks = \&InMessage;
#         If a message is received then this sub will run during
#         the process command
#         i.e.: $Connection->Process();
#
########################################################################
sub InMessage
{
	#Get the stream id
	my $sid = shift;
	#Get the actuall message
	my $message = shift;

	#show all the xml that's getting sent to the bot.  Only for debugging and figure stuff out.
	print $message->GetXML() if ($showXMLin);

	#Get the parts of the message that are interesting
	my $type = $message->GetType();
	my $from = $message->GetFrom("jid")->GetUserID();
	my $res = $message->GetFrom("jid")->GetResource();
	my $body = $message->GetBody();

	$TheMess = $body;
	chomp($TheMess);
	#get rid of leading or trailing whitespaces
	$TheMess =~ s/^\s*//;
	$TheMess =~ s/\s*$//;
	$TheUser = $from;
	if (lc($type) eq "groupchat") {
		$TheUser = $res;
		$mode = 'chat';
	} elsif (lc($type) eq 'chat') {
		my @tmp = split('/', $message->GetFrom('jid')->GetJID('full'));
		$TheUser = $tmp[1];
		$mode = 'console';
	}

	#If the message was sent by the bot then ignore it
	if ($TheUser eq $setup{NICK}) {
		$TheUser = "";
		$TheMess = "";
	} else {
		$lastinput = time;
	}
}


########################################################################
#
#  say - sends a message to the group chat channel that it's in.
#  usage: &say($string);
#
########################################################################
sub say
{
	my $tosend = shift;
	my $to = '';
	my $type = '';
	if ($mode eq 'console') {
		$to = $setup{ROOM} . '/' . $TheUser;
		$type = 'chat';
	} else {
		$to = $setup{ROOM};
		$type = 'groupchat';
	}
	my $to = ($mode eq 'console') ? $setup{ROOM} . '/' . $TheUser : $setup{ROOM};
	#create the question message
	my $Question = new Net::Jabber::Message;
	$Question->SetMessage(from => $setup{FULLID},
	                      to => $to,
	                      type => $type,
	                      body => $tosend);
	#send the question
	$Connection->Send($Question);
}


########################################################################
#
#  Send Help - Outputs a list of possible commands
#  usage: &SendHelp;
#
########################################################################
sub SendHelp
{
	my $message = "\nДевяточка - тохоняшечка и вовсе не трансвестит!\n";
	$message .= "!help - Мануал для дебилов\n";
	$message .= "!tits - Показать сисечки ^-^\n";
	$message .= "!coolstory - Рассказать охуительную историю\n";
	$message .= "!cartoon - Посоветовать мультик\n" if (%titles);
	$message .= "!hentai (*tags) - Фап-фап-фап\n";
	$message .= "!azaza - Рассказать отличную искромётную шутку\n";
	$message .= "!talk - Пообщаться с тохозадротом на откровенные темы\n";
	$message .= "!owner - Рассказать, с кем я больше всего люблю заниматься сексом ^///^";
	&say($message);
}


########################################################################
#
#  Leave Room - logs the trivia bot out of the room but not off the server
#  usage: &LeaveRoom;
#
########################################################################
sub LeaveRoom
{
	#Send presence with the resource of unavaible to the chat room
	$Connection->PresenceSend(from => $setup{FULLID},
	                          to => $setup{ROOM} . "/" . $setup{NICK},
	                          type => "unavailable");
}


########################################################################
#
#  Enter Room - Log the trivia bot into the room chosen from setup
#  usage: &EnterRoom
#
########################################################################
sub EnterRoom
{
	#Enter the trivia room
	$Connection->PresenceSend(from => $setup{FULLID}, to => $setup{ROOM} . "/" . $setup{NICK});
}


########################################################################
#
#  Increment Krolek bot counter if needed
#  usage: &ProcessDogCounter
#
########################################################################
sub ProcessDogCounter
{
	if ($TheUser eq $setup{DOGE}) {
		$DogCounter++;
	} else {
		$DogCounter = 0;
	}
}


########################################################################
#
#  Have a sex ^-^
#  usage: &Sex
#
########################################################################
sub Sex
{
	if ($TheUser eq $setup{OWNER}) {
		&say('Oh, yeah, my sweet ' . $TheUser);
	} else {
		&say('Не для тебя, ' . $TheUser . ', Ухта Девяточку растила D:');
	}
}


########################################################################
#
#  Show tits ^-^
#  usage: &Tits
#
########################################################################
sub Tits
{
	if ($TheUser eq $setup{OWNER}) {
		&say('Tits! ^-^ ( . )( . )');
	} else {
		&say('死ね！');
	}
}


########################################################################
#
#  Answer to Krolek's bot if it becomes annoying
#  usage: &Doge
#
########################################################################
sub Doge
{
	my $forMe = (index(lc($TheMess), lc($setup{NICK})) != -1);
	my $forOwner = (index(lc($TheMess), lc($setup{OWNER})) != -1);
	my $sleep = $TheMess =~ m/сп(и|ать)/i;
	if (($DogCounter >= $setup{DOGE_THRESHOSLD}) || ($forOwner && $sleep) || $forMe) {
		&say('Собака, иди нахуй!');
		$DogCounter = 0;
		return 1;
	}
	return 0;
}


########################################################################
#
#  Tell a cool story
#  usage: &CoolStory
#
########################################################################
sub CoolStory
{
	if (!@coolStories) {
		my $html = get 'http://zadolba.li/random/';
		my @storiesRaw = $html =~ m/<div\ class=\'text\'>(.*?)<\/div>/sgi;
		if (!@storiesRaw) {
			&say('Что-то снова пошло не так... :(');
			return;
		}
		foreach my $storyRaw (@storiesRaw) {
			my $story = $storyRaw =~ s/((<br\s*\/?>)|(<\/p><p>))+/\n/rg =~ s/^\R*//srg =~ s/<[^>]*>//rg;
			chomp($story);
			push(@coolStories, decode_entities($story));
		}
	}
	my $message = shift @coolStories;
	&say($message);
}


########################################################################
#
#  Show a link to a random korean cartoon
#  usage: &Cartoon
#  FIXME: Fetch titles for some external source cause this XML-file is a piece of old shit
#
########################################################################
sub Cartoon
{
	if (%titles) {
		my $randId = (keys %titles)[rand keys %titles];
		my $title = $titles{$randId};
		my $message = 'Наверни-ка "' . $title . '", ' . $TheUser . '. (http://anidb.net/perl-bin/animedb.pl?show=anime&aid=' . $randId . ')';
		&say($message);
	}
}

########################################################################
#
#  Ask a cool question from otvet.mail.ru
#  usage: &MrQuestion
#
########################################################################
sub MrQuestion
{
	if (!@questions) {
		# TODO: Move questions category to the config
		my $json = get 'http://otvet.mail.ru/api/v2/questlist?n=100&state=A&cat=adult';
		my @question_refs = @{${decode_json $json}{qst}};
		foreach my $question_ref (@question_refs) {
			push(@questions, ${$question_ref}{qtext});
		}
	}

	if (@questions) {
		&say(shift @questions);
	}
}


########################################################################
#
#  Find hentai comic by a tag
#  usage: &Hentai($tag)
#
########################################################################
sub Hentai
{
	my $tag = shift;
	my $url = 'http://g.e-hentai.org/?f_doujinshi=1&f_manga=1&f_artistcg=0&f_gamecg=0&f_western=0&f_non-h=0&f_imageset=0&f_cosplay=0&f_asianporn=0&f_misc=0&f_srdd=5&f_search=' . uri_escape_utf8($tag);
	my $html = get $url;
	my @pages = $html =~ m/onclick\=\"sp\(\d+\)\"/sgi;
	my $lastPage = 0;
	my $page = 0;
	foreach my $pageRaw (@pages) {
		$page = $pageRaw =~ s/^.*\(//r =~ s/\).*$//r;
		if ($page > $lastPage) {
			$lastPage = $page;
		}
	}
	my $randPage = int(rand($lastPage));
	if ($randPage > 1) {
		$url .= '&page=' . $randPage;
		$html = get $url;
	}
	my @comicRaw = $html =~ m/\<td\ class\=\"itd\"\ onmouseover\=\"preload_pane_image_delayed\(.*?\<\/td\>/sgi;
	my $message = '';
	if (scalar(@comicRaw) == 0) {
		$message = 'Правило 34 не действует на ' . $tag . ', ' . $TheUser . '. :(';
	} else {
		my $comic = @comicRaw[rand keys @comicRaw];
		my @hrefs = $comic =~ m/http\:\/\/g\.e\-hentai\.org\/g\/\d+?\/.+?\//gi;
		my $href = $hrefs[0];
		my $title = $comic =~ s/^.*\<div\ class=\"it5\"\>//r =~ s/\<\/div\>.*$//r =~ s/\<[^>]*\>//gr;
		$message = decode_entities($title) . ' (' . $href . ')';
	}
	&say($message);
}


########################################################################
#
#  Who Owns Me - displays some owner information about this bot.
#  usage: &WhoOwnsMe;
#
########################################################################
sub WhoOwnsMe
{
	&say($setup{OWNER});
}


########################################################################
#
#  Tell a very funny joke
#  usage: &CoolJoke;
#
########################################################################
sub CoolJoke
{
	my $html = get 'http://nya.sh/';
	my $last = $html =~ s/.*<div align="center" class="pages">Страницы: <b>//sr =~ s/<\/b>.*//rs;
	my @pages = ();
	for (my $i = 0; $i <= $last; $i++) {
		push(@pages, $i * 50);
	}
	my $page = @pages[rand keys @pages];
	if ($page > 0) {
		$html = get "http://nya.sh/page/$page";
	}
	my @jokes = $html =~ m/<div class="content">.*?<\/div>/gi;
	my $joke = @jokes[rand keys @jokes] =~ s/<br\s+\/?>/\R/rgi =~ s/<[^>]*>//rg;
	&say(decode_entities($joke));
}


########################################################################
#
#  Check For Command - Checks if a bot command has been given
#  It assumes that the command is in $TheMess
#  If there was a command at all.
#  usage: &CheckForCommand;
#
########################################################################
sub CheckForCommand
{
	my $res = 1;
	my $sexMessage = 'how about a cup of sex';
	my $messageLower = lc($TheMess);
	my $forMe = (index($messageLower, lc($setup{NICK})) != -1);
	&ProcessDogCounter;

	if ($TheUser eq $setup{DOGE}) {
		$res = &Doge;

	} elsif ($forMe && index($messageLower, $sexMessage) != -1) {
		&Sex;

	} elsif ($messageLower eq '!help') {
		&SendHelp;

	} elsif ($messageLower eq '!tits') {
		&Tits;

	} elsif ($messageLower eq '!coolstory') {
		&CoolStory;

	} elsif ($messageLower eq '!cartoon') {
		&Cartoon;

	} elsif ($messageLower eq '!owner') {
		&WhoOwnsMe;

	} elsif ($messageLower eq '!talk') {
		&MrQuestion;

	} elsif ($messageLower =~ m/^!hentai\s*/) {
		my $tag = $messageLower =~ s/^\!hentai\s+//ir;
		&Hentai($tag);

	} elsif ($messageLower =~ m/^!azaza\s*/) {
		&CoolJoke;

#	} elsif ($messageLower eq '!loli') {
#		#FIXME: Doesn't work at all
#		&Hentai('loli');
	} else {
		$res = 0;
	}
	return $res;
}


########################################################################
#
#  Check For Command - Checks if a bot command has been given in
#                      private console
#  usage: &CheckForConsoleCommand;
#
########################################################################
sub CheckForConsoleCommand
{
	if(!($TheUser ~~ @administrators)) {
		&say('You are not in administrators list');
		return 0;
	}
	my ($command, @args) = &ParseConsoleCommand();
	return defined($command) && defined($consoleHandlers{$command}) ? $consoleHandlers{$command}(@args) : 0;
}

########################################################################
#
#  Parse console command to params array private console
#  usage: &ParseConsoleCommand;
#
########################################################################
sub ParseConsoleCommand
{
	if (!$TheMess) {
		return (undef, ());
	}
	my @parts = split(' ', $TheMess);
	return (shift @parts, @parts);
}

########################################################################
#
#  Authorisation handler
#  usage: &ParseConsoleCommand;
#
########################################################################
sub Auth
{
	my $credentials = $TheUser . '::' . md5(join(' ', @_));
	foreach my $admin (@administrators) {
		if ($admin eq $credentials) {
			push(@adminSessions, $credentials);
			&say(join(',', @adminSessions));
			return 1;
		}
	}
	return 0;
}
