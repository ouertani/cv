#!/usr/bin/env perl
# $Id: install-tl 39362 2016-01-12 03:24:41Z preining $
# 
# Copyright 2007-2015
# Reinhard Kotucha, Norbert Preining, Karl Berry, Siep Kroonenberg.
# This file is licensed under the GNU General Public License version 2
# or any later version.
#
# Be careful when changing wording: *every* normal informational message
# output here must be recognized by the long grep in tl-update-tlnet.
#
# TODO:
# - with -gui pop up a transient window showing:
#      testing for compressed archive packages ...
#      testing for uncompressed live system ...
#      testing for network access ...
#      loading tlpdb, this can take some time ...
#   (that, and maybe some others can be done with the waitVariableX
#   thingy as described in the Perl/Tk book in the chapter that can be
#   found on the net)   (Werner 28.10.08)

my $svnrev = '$Revision: 39362 $';
$svnrev =~ m/: ([0-9]+) /;
$::installerrevision = $1;

# taken from 00texlive.config: release, $tlpdb->config_release;
our $texlive_release;

BEGIN {
  $^W = 1;
  my $Master;
  my $me = $0;
  $me =~ s!\\!/!g if $^O =~ /^MSWin(32|64)$/i;
  if ($me =~ m!/!) {
    ($Master = $me) =~ s!(.*)/[^/]*$!$1!;
  } else {
    $Master = ".";
  }
  $::installerdir = $Master;

  # All platforms: add the installer modules
  unshift (@INC, "$::installerdir/tlpkg");
}

use Cwd 'abs_path';
use Getopt::Long qw(:config no_autoabbrev);
use Pod::Usage;

use TeXLive::TLUtils qw(platform platform_desc sort_archs
   which getenv win32 unix info log debug tlwarn ddebug tldie
   get_system_tmpdir member process_logging_options rmtree wsystem
   mkdirhier make_var_skeleton make_local_skeleton install_package copy
   install_packages dirname setup_programs native_slashify forward_slashify);
use TeXLive::TLPOBJ;
use TeXLive::TLPDB;
use TeXLive::TLConfig;
use TeXLive::TLDownload;
use TeXLive::TLPaper;

if (win32) {
  require TeXLive::TLWinGoo;
  TeXLive::TLWinGoo->import( qw(
    &win_version
    &is_vista
    &admin
    &non_admin
    &reg_country
    &expand_string
    &global_tmpdir
    &get_system_path
    &get_user_path
    &setenv_reg
    &unsetenv_reg
    &adjust_reg_path_for_texlive
    &register_extension
    &unregister_extension
    &register_file_type
    &unregister_file_type
    &broadcast_env
    &update_assocs
    &add_desktop_shortcut
    &add_menu_shortcut
    &remove_desktop_shortcut
    &remove_menu_shortcut
    &create_uninstaller
  ));
}

use strict;

# global list of lines that get logged (see TLUtils.pm::_logit).
@::LOGLINES = ();

# global list of warnings
@::WARNLINES = ();

# we play around with the environment, place to keep original
my %origenv = ();

# $install{$packagename} == 1 if it should be installed
my %install;

# the different modules have to assign a code blob to this global variable
# which starts the installation.
# Example: In install-menu-text.pl there is
#   $::run_menu = \&run_menu_text;
#
$::run_menu = sub { die "no UI defined." ; };

# the default scheme to be installed
my $default_scheme='scheme-full';

# common fmtutil args, keep in sync with tlmgr.pl.
our $common_fmtutil_args =
  "--no-error-if-no-engine=$TeXLive::TLConfig::PartialEngineSupport";

# some arrays where the lists of collections to be installed are saved
# our for menus
our @collections_std;

# The global variable %vars is an associative list which contains all
# variables and their values which can be changed by the user.
# needs to be our since TeXLive::TLUtils uses it
#
# The following values are taken from the remote tlpdb using the
#   $tlpdb->option_XXXXX
# settings (i.e., taken from tlpkg/tlpsrc/00texlive.installation.tlpsrc
#
#        'option_path' => 0,
#        'option_sys_bin' => '/usr/local/bin',
#        'option_sys_man' => '/usr/local/man',
#        'option_sys_info' => '/usr/local/info',
#        'option_doc' => 1,
#        'option_src' => 1,
#        'option_fmt' => 0,
#        'option_letter' => 0,
#        'option_adjustrepo' => 1,
our %vars=( # 'n_' means 'number of'.
        'this_platform' => '',
        'n_systems_available' => 0,
        'n_systems_selected' => 0,
        'n_collections_selected' => 0,
        'n_collections_available' => 0,
        'total_size' => 0,
        'src_splitting_supported' => 1,
        'doc_splitting_supported' => 1,
        'selected_scheme' => $default_scheme,
        'in_place' => 0,
        'portable' => 0,
    );

# option handling
my $opt_in_place = 0;
my $opt_gui = (win32() ? "wizard" : "text");
my $opt_help = 0;
my $opt_location = "";
my $opt_no_gui = 0;
my $opt_nonadmin = 0;
my $opt_portable = 0;
my $opt_print_arch = 0;
my $opt_profileseed = "";
my $opt_profile = "";
my $opt_scheme = "";
my $opt_custom_bin;
my $opt_version = 0;
my $opt_force_arch;
my $opt_persistent_downloads = 1;
my $opt_allow_ftp = 0;
$::opt_select_repository = 0;

# show all options even those not relevant for that arch
$::opt_all_options = 0;

# default language for GUI installer
$::lang = "en";

# use the fancy directory selector for TEXDIR
$::alternative_selector = 0;

# do not debug translations by default
$::debug_translation = 0;

# some strings to describe the different meanings of option_file_assoc
$::fileassocdesc[0] = "None";
$::fileassocdesc[1] = "Only new";
$::fileassocdesc[2] = "All";

# if we find a file installation.profile we ask the user whether we should
# continue with the installation
# note, we are in the installer directory.
if (-r "installation.profile") {
  my $pwd = Cwd::getcwd();
  print "ABORTED TL INSTALLATION FOUND: installation.profile (in $pwd)\n";
  print "Do you want to continue with the exact same settings as before (y/N): ";
  my $answer = <STDIN>;
  if ($answer =~ m/^y(es)?$/i) {
    $opt_profile = "installation.profile";
  }
}


# first process verbosity/quiet options
process_logging_options();
# now the others
GetOptions(
           "custom-bin=s"                => \$opt_custom_bin,
           "fancyselector"               => \$::alternative_selector,
           "in-place"                    => \$opt_in_place,
           "gui:s"                       => \$opt_gui,
           "lang=s"                      => \$::opt_lang,
           "location|url|repository|repos|repo=s" => \$opt_location,
           "no-cls",                    # $::opt_no_cls in install-menu-text-pl
           "no-gui"                      => \$opt_no_gui,
           "non-admin"                   => \$opt_nonadmin,
           "portable"                    => \$opt_portable,
           "print-platform|print-arch"   => \$opt_print_arch,
           "force-platform|force-arch=s" => \$opt_force_arch,
           "debug-translation"           => \$::debug_translation,
           "profile-seed=s"              => \$opt_profileseed,
           "profile=s"                   => \$opt_profile,
           "scheme=s"                    => \$opt_scheme,
           "all-options"                 => \$::opt_all_options,
           "persistent-downloads!"       => \$opt_persistent_downloads,
           "select-repository"           => \$::opt_select_repository,
           "version"                     => \$opt_version,
           "help|?"                      => \$opt_help) or pod2usage(1);

if ($opt_gui eq "") {
  # the --gui option was given with an empty argument, set it to perltk
  $opt_gui = "perltk";
}
if ($opt_gui eq "expert") {
  $opt_gui = "perltk";
}

if ($opt_help) {
  # theoretically we could make a subroutine with all the same
  # painful checks as we do in tlmgr, but let's not bother until people ask.
  my @noperldoc = ();
  if (win32() || $ENV{"NOPERLDOC"}) {
    @noperldoc = ("-noperldoc", "1");
  }

  # Tweak less stuff same as tlmgr, though.
  # less can break control characters and thus the output of pod2usage
  # is broken.  We add/set LESS=-R in the environment and unset
  # LESSPIPE and LESSOPEN to try to help.
  # 
  if (defined($ENV{'LESS'})) {
    $ENV{'LESS'} .= " -R";
  } else {
    $ENV{'LESS'} = "-R";
  }
  delete $ENV{'LESSPIPE'};
  delete $ENV{'LESSOPEN'};

  pod2usage(-exitstatus => 0, -verbose => 2, @noperldoc);
  die "sorry, pod2usage did not work; maybe a download failure?";
}

if ($opt_version) {
  print "install-tl (TeX Live Cross Platform Installer)",
        " revision $::installerrevision\n";
  if (open (REL_TL, "$::installerdir/release-texlive.txt")) {
    # print first and last lines, which have the TL version info.
    my @rel_tl = <REL_TL>;
    print $rel_tl[0];
    print $rel_tl[$#rel_tl];
    close (REL_TL);
  }
  if ($::opt_verbosity > 0) {
    print "Revision of modules:";
    print "\nTLConfig: " . TeXLive::TLConfig->module_revision();
    print "\nTLUtils:  " . TeXLive::TLUtils->module_revision();
    print "\nTLPOBJ:   " . TeXLive::TLPOBJ->module_revision();
    print "\nTLPDB:    " . TeXLive::TLPDB->module_revision();
    print "\nTLWinGoo: " . TeXLive::TLWinGoo->module_revision() if win32();
    print "\n";
  }
  exit 0;
}

die "$0: Options custom-bin and in-place are incompatible.\n"
  if ($opt_in_place && $opt_custom_bin);

die "$0: Options profile and in-place are incompatible.\n"
  if ($opt_in_place && $opt_profile);

die "$0: Options profile-seed and in-place are incompatible.\n"
  if ($opt_in_place && $opt_profileseed);

if ($#ARGV >= 0) {
  # we still have arguments left, should only be gui, otherwise die
  if ($ARGV[0] =~ m/^gui$/i) {
    $opt_gui = "perltk";
  } else {
    die "$0: Extra arguments `@ARGV'; try --help if you need it.\n";
  }
}


if (defined($::opt_lang)) {
  $::lang = $::opt_lang;
}

if ($opt_profile) { # for now, not allowed if in_place
  if (-r $opt_profile) {
    info("Automated TeX Live installation using profile: $opt_profile\n");
  } else {
    $opt_profile = "";
    info("Profile $opt_profile not readable, continuing in interactive mode.\n");
  }
}

if ($opt_nonadmin and win32()) {
  non_admin();
}


# the TLPDB instances we will use. $tlpdb is for the one from the installation
# media, while $localtlpdb is for the new installation
# $tlpdb must be our because it is used in install-menu-text.pl
our $tlpdb;
my $localtlpdb;
my $location;

# $finished == 1 if the menu call already did the installation
my $finished = 0;
@::info_hook = ();

my $system_tmpdir=get_system_tmpdir();
our $media;
our @media_available;

# special uses of install-tl:
if ($opt_print_arch) {
  print platform()."\n";
  exit 0;
}


# continuing with normal install

# check as soon as possible for GUI functionality to give people a chance
# to interrupt.
if (($opt_gui ne "text") && !$opt_no_gui && ($opt_profile eq "")) {
  # try to load Tk.pm, but don't die if it doesn't work
  eval { require Tk; };
  if ($@) {
    # that didn't work out, so warn the user and continue with text mode
    tlwarn("Cannot load Tk, maybe something is missing and\n");
    tlwarn("maybe http://tug.org/texlive/distro.html#perltk can help.\n");
    tlwarn("Error message from loading Tk:\n");
    tlwarn("  $@\n");
    tlwarn("Continuing in text mode...\n");
    $opt_gui = "text";
  }
  eval { my $foo = Tk::MainWindow->new; $foo->destroy; };
  if ($@) {
    tlwarn("perl/Tk unusable, cannot create main window.\n");
    if (platform() eq "universal-darwin") {
      tlwarn("That could be because X11 is not installed or started.\n");
    }
    tlwarn("Error message from creating MainWindow:\n");
    tlwarn("  $@\n");
    tlwarn("Continuing in text mode...\n");
    $opt_gui = "text";
  }
  if ($opt_gui eq "text") {
    # we switched from GUI to non-GUI mode, tell the user and wait a bit
    tlwarn("\nSwitching to text mode installer, if you want to cancel, do it now.\n");
    tlwarn("Waiting for 3 seconds\n");
    sleep(3);
  }
}

#
if (defined($opt_force_arch)) {
  tlwarn("Overriding platform to $opt_force_arch\n");
  $::_platform_ = $opt_force_arch;
}

# initialize the correct platform
platform();
$vars{'this_platform'} = $::_platform_;

# we do not support cygwin < 1.7, so check for that
if (!$opt_custom_bin && (platform() eq "i386-cygwin")) {
  chomp( my $un = `uname -r`);
  if ($un =~ m/^(\d+)\.(\d+)\./) {
    if ($1 < 2 && $2 < 7) {
      tldie("\nSorry, the TL binaries require at least cygwin 1.7.\n");
    }
  }
}

# determine which media are available, don't put NET here, it is
# assumed to be available at any time
{
  # check the installer dir for what is present
  my $tmp = $::installerdir;
  $tmp = abs_path($tmp);
  # remove trailing \ or / (e.g. root of dvd drive on w32)
  $tmp =~ s,[\\\/]$,,;
  if (-d "$tmp/$Archive") {
    push @media_available, "local_compressed#$tmp";
  }
  if (-r "$tmp/texmf-dist/web2c/texmf.cnf") {
    push @media_available, "local_uncompressed#$tmp";
  }
}

# check command line arguments if given
if ($opt_location) {
  my $tmp = $opt_location;
  if ($tmp =~ m!^(http|ftp)://!i) {
    push @media_available, "NET#$tmp";

  } elsif ($tmp =~ m!^(rsync|)://!i) {
    tldie ("$0: sorry, rsync unsupported; use an http or ftp url here.\n"); 

  } else {
    # remove leading file:/+ part
    $tmp =~ s!^file://*!/!i;
    $tmp = abs_path($tmp);
    # remove trailing \ or / (e.g. root of dvd drive on w32)
    $tmp =~ s,[\\\/]$,,;
    if (-d "$tmp/$Archive") {
      push @media_available, "local_compressed#$tmp";
    }
    if (-d "$tmp/texmf-dist/web2c") {
      push @media_available, "local_uncompressed#$tmp";
    }
  }
}

if (!setup_programs ("$::installerdir/tlpkg/installer", "$::_platform_")) {
  tldie("$0: Goodbye.\n");
}


if ($opt_profile eq "") {
  if ($opt_profileseed) {
    read_profile("$opt_profileseed");
  }
  # do the normal interactive installation.
  #
  # here we could load different menu systems. Currently several things
  # are "our" so that the menu implementation can use it. The $tlpdb, the
  # %var, and all the @collection*
  # install-menu-*.pl have to assign a code ref to $::run_menu which is
  # run, and should change ONLY stuff in %vars
  # The allowed keys in %vars should be specified somewhere ...
  # the menu implementation should return
  #    MENU_INSTALL  do the installation
  #    MENU_ABORT    abort every action immediately, no cleanup
  #    MENU_QUIT     try to quit and clean up mess
  our $MENU_INSTALL = 0;
  our $MENU_ABORT   = 1;
  our $MENU_QUIT    = 2;
  our $MENU_ALREADYDONE = 3;
  $opt_gui = "text" if ($opt_no_gui);
  # finally do check for additional screens in the $opt_gui setting:
  # format:
  #   --gui <plugin>:<a1>,<a2>,...
  # which will passed to run_menu (<a1>, <a2>, ...)
  #
  my @runargs;
  if ($opt_gui =~ m/^([^:]*):(.*)$/) {
    $opt_gui = $1;
    @runargs = split ",", $2;
  }
  if (-r "$::installerdir/tlpkg/installer/install-menu-${opt_gui}.pl") {
    require("installer/install-menu-${opt_gui}.pl");
  } else {
    tlwarn("UI plugin $opt_gui not found,\n");
    tlwarn("Using text mode installer.\n");
    require("installer/install-menu-text.pl");
  }

  # before we start the installation we check for the existence of
  # a previous installation, and in case we ship inform the UI
  {
    my $tlmgrwhich = which("tlmgr");
    if ($tlmgrwhich) {
      my $dn = dirname($tlmgrwhich);
      $dn = abs_path("$dn/../..");
      # The "make Karl happy" case, check that we are not running install-tl
      # from the same tree where tlmgr is hanging around
      my $install_tl_root = abs_path($::installerdir);
      my $tlpdboldpath = "$dn/$TeXLive::TLConfig::InfraLocation/$TeXLive::TLConfig::DatabaseName";
      if (-r $tlpdboldpath && $dn ne $install_tl_root) {
        debug ("found old installation in $dn\n");
        push @runargs, "-old-installation-found=$dn";
      }
    }
  }

  my $ret = &{$::run_menu}(@runargs);
  if ($ret == $MENU_QUIT) {
    do_cleanup();
    flushlog();
    exit(1);
  } elsif ($ret == $MENU_ABORT) {
    # omit do_cleanup().
    flushlog();
    exit(2);
  } elsif ($ret == $MENU_ALREADYDONE) {
    debug("run_menu has already done the work ... cleaning up.\n");
    $finished = 1;
  }
  if (!$finished && ($ret != $MENU_INSTALL)) {
    tlwarn("Unknown return value of run_menu: $ret\n");
    exit(3);
  }
} else {
  if (!do_remote_init()) {
    die ("Exiting installation.\n");
  }
  read_profile($opt_profile);
}

my $varsdump = "";
foreach my $key (sort keys %vars) {
  $varsdump .= "  $key: \"" . $vars{$key} . "\"\n";
}
log("Settings:\n" . $varsdump);

my $errcount = 0;
if (!$finished) {
  # do the actual installation
  # w32: first, remove trailing slash from texdir[w]
  # in case it is the root of a drive
  $vars{'TEXDIR'} =~ s![/\\]$!!;
  sanitise_options();
  info("Installing to: $vars{TEXDIR}\n");
  $errcount = do_installation();
}

do_cleanup();

my $status = 0;
if ($errcount > 0) {
  $status = 1;
  warn "$0: errors in installation reported above,\n";
  warn "$0: exiting with bad status.\n";
}
exit($status);



###################################################################
#
# FROM HERE ON ONLY SUBROUTINES
# NO VARIABLE DECLARATIONS OR CODE
#
###################################################################

#
# SETUP OF REMOTE STUFF
#
# this is now a sub since it is called from the ui plugins on demand
# this allows selecting a mirror first and then continuing

sub only_load_remote {
  my $selected_location = shift;

  # determine where we will find the distribution to install from.
  #
  $location = $opt_location;
  $location = $selected_location if defined($selected_location);
  $location || ($location = "$::installerdir");
  if ($location =~ m!^(ctan$|(http|ftp)://)!i) {
    $location =~ s,/(tlpkg|archive)?/*$,,;  # remove any trailing tlpkg or /
    if ($location =~ m/^ctan$/i) {
      $location = TeXLive::TLUtils::give_ctan_mirror();
    } elsif ($location =~ m/^$TeXLiveServerURL/) {
      my $mirrorbase = TeXLive::TLUtils::give_ctan_mirror_base();
      $location =~ s,^($TeXLiveServerURL|ctan$),$mirrorbase,;
    }
    $TeXLiveURL = $location;
    $media = 'NET';
  } else {
    if (scalar grep($_ =~ m/^local_compressed/, @media_available)) {
      $media = 'local_compressed';
      # for in_place option we want local_uncompressed media
      $media = 'local_uncompressed' if $opt_in_place &&
        member('local_uncompressed', @media_available);
    } elsif (scalar grep($_ =~ m/^local_uncompressed/, @media_available)) {
      $media = 'local_uncompressed';
    } else {
      if ($opt_location) {
        # user gave a --location but nothing can be found there, so die
        die "$0: cannot find installation source at $opt_location.\n";
      }
      # no --location given, but NET installation
      $TeXLiveURL = $location = TeXLive::TLUtils::give_ctan_mirror();
      $media = 'NET';
    }
  }
  return load_tlpdb();
}


sub do_remote_init {
  if (!only_load_remote(@_)) {
    tlwarn("$0: Could not load TeX Live Database from $location, goodbye.\n");
    return 0;
  }
  if (!do_version_agree()) {
    TeXLive::TLUtils::tldie <<END_MISMATCH;
=============================================================================
$0: The TeX Live versions of the local installation
and the repository being accessed are not compatible:
      local: $TeXLive::TLConfig::ReleaseYear
 repository: $texlive_release
Perhaps you need to use a different CTAN mirror?
(For more, see the output of install-tl --help, especially the
 -repository option.  Online via http://tug.org/texlive/doc.)
=============================================================================
END_MISMATCH
  }
  final_remote_init();
  return 1;
}

sub do_version_agree {
  $texlive_release = $tlpdb->config_release;
  if ($media eq "local_uncompressed") {
    # existing installation may not have 00texlive.config metapackage
    # so use TLConfig to establish what release we have
    $texlive_release ||= $TeXLive::TLConfig::ReleaseYear;
  }

  # if the release from the remote TLPDB does not agree with the
  # TLConfig::ReleaseYear in the first 4 places break out here.
  # Why only the first four places: some optional network distributions
  # might use
  #   release/2009-foobar
  if ($media eq "NET"
      && $texlive_release !~ m/^$TeXLive::TLConfig::ReleaseYear/) {
    return 0;
  } else {
    return 1;
  }
}

sub final_remote_init {
  info("Installing TeX Live $TeXLive::TLConfig::ReleaseYear from: $location\n");

  info("Platform: ", platform(), " => \'", platform_desc(platform), "\'\n");
  if ($opt_custom_bin) {
    if (-d $opt_custom_bin && (-r "$opt_custom_bin/kpsewhich"
                               || -r "$opt_custom_bin/kpsewhich.exe")) {
      info("Platform overridden, binaries taken from $opt_custom_bin\n"
           . "and will be installed into .../bin/custom.\n");
    } else {
      tldie("$opt_custom_bin: Argument to -custom-bin must be a directory "
            . "with TeX Live binaries.\n");
    }
  }
  if ($media eq "local_uncompressed") {
    info("Distribution: live (uncompressed)\n");
  } elsif ($media eq "local_compressed") {
    info("Distribution: inst (compressed)\n");
  } elsif ($media eq "NET") {
    info("Distribution: net  (downloading)\n");
    info("Using URL: $TeXLiveURL\n");
    TeXLive::TLUtils::setup_persistent_downloads() if $opt_persistent_downloads;
  } else {
    info("Distribution: $media\n");
  }
  info("Directory for temporary files: $system_tmpdir\n");

  if ($opt_in_place and ($media ne "local_uncompressed")) {
    print "TeX Live not local or not decompressed; 'in_place' option not applicable\n";
    $opt_in_place = 0;
  } elsif ($opt_in_place and (!TeXLive::TLUtils::texdir_check($::installerdir))) {
    print "Installer dir not writable; 'in_place' option not applicable\n";
    $opt_in_place = 0;
  }
  $vars{'in_place'} = $opt_in_place;
  $opt_scheme = "" if $opt_in_place;
  $vars{'portable'} = $opt_portable;

  log("Installer revision: $::installerrevision\n");
  log("Database revision: " . $tlpdb->config_revision . "\n");

  # correctly set the splitting support
  # for local_uncompressed we always support splitting
  if (($media eq "NET") || ($media eq "local_compressed")) {
    $vars{'src_splitting_supported'} = $tlpdb->config_src_container;
    $vars{'doc_splitting_supported'} = $tlpdb->config_doc_container;
  }
  set_platforms_supported();
  set_texlive_default_dirs();
  set_install_platform();
  initialize_collections();

  # initialize the scheme from the command line value, if given.
  if ($opt_scheme) {
    # add the scheme- prefix if they didn't give it.
    $opt_scheme = "scheme-$opt_scheme" if $opt_scheme !~ /^scheme-/;
    my $scheme = $tlpdb->get_package($opt_scheme);
    if (defined($scheme)) {
      select_scheme($opt_scheme);  # select it
    } else {
      tlwarn("Scheme $opt_scheme not defined, ignoring it.\n");
    }
  }
}


sub do_installation {
  install_warnlines_hook();
  if (win32()) {
    non_admin() if !$vars{'option_w32_multi_user'};
  }
  if ($vars{'n_collections_selected'} <= 0) {
    tlwarn("Nothing selected, nothing to install, exiting!\n");
    exit 1;
  }
  # remove final slash from TEXDIR even if it is the root of a drive
  $vars{'TEXDIR'} =~ s!/$!!;
  # do the actual installation
  make_var_skeleton "$vars{'TEXMFSYSVAR'}";
  make_local_skeleton "$vars{'TEXMFLOCAL'}";
  mkdirhier "$vars{'TEXMFSYSCONFIG'}";

  if ($vars{'in_place'}) {
    $localtlpdb = $tlpdb;
  } else {
    $localtlpdb=new TeXLive::TLPDB;
    $localtlpdb->root("$vars{'TEXDIR'}");
  }
  if (!$vars{'in_place'}) {
    # have to do top-level release-texlive.txt as a special file, so
    # tl-update-images can insert the final version number without
    # having to remake any packages.  But if the source does not exist,
    # or the destination already exists, don't worry about it (even
    # though these cases should never arise); it's not that important.
    #
    if (-e "$::installerdir/release-texlive.txt"
        && ! -e "$vars{TEXDIR}/release-texlive.txt") {
      copy("$::installerdir/release-texlive.txt", "$vars{TEXDIR}/");
    }
    
    calc_depends();
    save_options_into_tlpdb();
    # we need to do that dir, since we use the TLPDB->install_package which
    # might change into texmf-dist for relocated packages
    mkdirhier "$vars{'TEXDIR'}/texmf-dist";
    do_install_packages();
    if ($opt_custom_bin) {
      $vars{'this_platform'} = "custom";
      my $TEXDIR="$vars{'TEXDIR'}";
      mkdirhier("$TEXDIR/bin/custom");
      for my $f (<$opt_custom_bin/*>) {
        copy($f, "$TEXDIR/bin/custom");
      }
    }
  }
  # now we save every scheme that is fully covered by the stuff we have
  # installed to the $localtlpdb
  foreach my $s ($tlpdb->schemes) {
    my $stlp = $tlpdb->get_package($s);
    die ("This cannot happen, $s not defined in tlpdb") if ! defined($stlp);
    my $incit = 1;
    foreach my $d ($stlp->depends) {
      if (!defined($localtlpdb->get_package($d))) {
        $incit = 0;
        last;
      }
    }
    if ($incit) {
      $localtlpdb->add_tlpobj($stlp);
    }
  }
  
  # include a 00texlive.config package in the new tlpdb,
  # so that further installations and updates using the new installation
  # as the source can work.  Only include the release info, the other
  # 00texlive.config entries are not relevant for this case.
  my $tlpobj = new TeXLive::TLPOBJ;
  $tlpobj->name("00texlive.config");
  my $t = $tlpdb->get_package("00texlive.config");
  $tlpobj->depends("minrelease/" . $tlpdb->config_minrelease,
                   "release/"    . $tlpdb->config_release);
  $localtlpdb->add_tlpobj($tlpobj);  
  
  $localtlpdb->save unless $vars{'in_place'};
  
  my $errcount = do_postinst_stuff();
  if (win32() || $vars{'portable'}) {
    print welcome();
  } else {
    print welcome_paths();
  }
  print warnings_summary();
  
  return $errcount;
}

sub run_postinst_cmd {
  my ($cmd) = @_;
  
  info ("running $cmd ...");
  my ($out,$ret) = TeXLive::TLUtils::run_cmd ("$cmd 2>&1");
  info ("done\n");
  log ($out);

  if ($ret != 0) {
    tlwarn ("$0: $cmd failed: $!\n");
    $ret = 1; # be sure we don't overflow the sum on anything crazy
  }
  
  return $ret;
}


# 
# Make texmf.cnf, backup directory, cleanups, path setting, and
# (most importantly) post-install subprograms: mktexlsr, fmtutil,
# and more.  Return count of errors detected, hopefully zero.
sub do_postinst_stuff {
  my $TEXDIR = "$vars{'TEXDIR'}";
  my $TEXMFSYSVAR = "$vars{'TEXMFSYSVAR'}";
  my $TEXMFSYSCONFIG = "$vars{'TEXMFSYSCONFIG'}";
  my $TEXMFVAR = "$vars{'TEXMFVAR'}";
  my $TEXMFCONFIG = "$vars{'TEXMFCONFIG'}";
  my $TEXMFLOCAL = "$vars{'TEXMFLOCAL'}";
  my $tmv;

  do_texmf_cnf();

  # clean up useless files in texmf-dist/tlpkg as this is only
  # created by the relocatable packages
  if (-d "$TEXDIR/$TeXLive::TLConfig::RelocTree/tlpkg") {
    rmtree("$TEXDIR/TeXLive::TLConfig::RelocTree/tlpkg");
  }

  # create package backup directory for tlmgr autobackup to work
  mkdirhier("$TEXDIR/$TeXLive::TLConfig::PackageBackupDir");

  # final program execution
  # we have to do several things:
  # - clean the environment from spurious TEXMF related variables
  # - add the bin dir to the PATH
  # - select perl interpreter and set the correct perllib
  # - run the programs

  # Step 1: Clean the environment.
  %origenv = %ENV;
  my @TMFVARS=qw(VARTEXFONTS
    TEXMF SYSTEXMF VARTEXFONTS
    TEXMFDBS WEB2C TEXINPUTS TEXFORMATS MFBASES MPMEMS TEXPOOL MFPOOL MPPOOL
    PSHEADERS TEXFONTMAPS TEXPSHEADERS TEXCONFIG TEXMFCNF
    TEXMFMAIN TEXMFDIST TEXMFLOCAL TEXMFSYSVAR TEXMFSYSCONFIG
    TEXMFVAR TEXMFCONFIG TEXMFHOME TEXMFCACHE);

  if (defined($ENV{'TEXMFCNF'})) {
    print "WARNING: environment variable TEXMFCNF is set.
You should know what you are doing.
We will unset it for the post-install actions, but all further
operations might be disturbed.\n\n";
  }
  foreach $tmv (@TMFVARS) {
    delete $ENV{$tmv} if (defined($ENV{$tmv}));
  }

  # Step 2: Setup the PATH, switch to the new Perl

  my $pathsep = (win32)? ';' : ':';
  my $plat_bindir = "$TEXDIR/bin/$vars{'this_platform'}";
  my $perl_bindir = "$TEXDIR/tlpkg/tlperl/bin";
  my $perl_libdir = "$TEXDIR/tlpkg/tlperl/lib";

  debug("Prepending $plat_bindir to PATH\n");
  $ENV{'PATH'} = $plat_bindir . $pathsep . $ENV{'PATH'};

  if (win32) {
    debug("Prepending $perl_bindir to PATH\n");
    $ENV{'PATH'} = "$perl_bindir" . "$pathsep" . "$ENV{'PATH'}";
    $ENV{'PATH'} =~ s!/!\\!g;
  }

  debug("\nNew PATH is:\n");
  foreach my $dir (split $pathsep, $ENV{'PATH'}) {
    debug("  $dir\n");
  }
  debug("\n");
  if (win32) {
    $ENV{'PERL5LIB'} = $perl_libdir;
  }

  #
  # post install actions
  #

  my $usedtlpdb = $vars{'in_place'} ? $tlpdb : $localtlpdb;

  if (win32()) {
    debug("Actual environment:\n" . `set` ."\n\n");
    debug("Effective TEXMFCNF: " . `kpsewhich -expand-path=\$TEXMFCNF` ."\n");
  }

  if (win32() and !$vars{'portable'} and !$vars{'in_place'}) {
    create_uninstaller($vars{'TEXDIR'});
    # TODO: custom uninstaller for in_place
    # (re-)initialize batchfile for uninstalling shortcuts
  }

  # Step 4: run the programs
  my $errcount = 0;

  if (!$vars{'in_place'}) {
    $errcount += wsystem("running", 'mktexlsr', "$TEXDIR/texmf-dist");
  }

  # we have to generate the various config file. That could be done with
  # texconfig generate * but Win32 does not have texconfig. But we have
  # $localtlpdb and this is simple code, so do it directly, i.e., duplicate
  # the code from the various generate-*.pl scripts

  mkdirhier "$TEXDIR/texmf-dist/web2c";
  info("writing fmtutil.cnf to $TEXDIR/texmf-dist/web2c/fmtutil.cnf\n");
  TeXLive::TLUtils::create_fmtutil($usedtlpdb,
    "$TEXDIR/texmf-dist/web2c/fmtutil.cnf");

  # warn if fmtutil-local.cnf is presetn
  if (-r "$TEXMFLOCAL/web2c/fmtutil-local.cnf") {
    tlwarn("Old configuration file $TEXMFLOCAL/web2c/fmtutil-local.cnf found.\n");
    tlwarn("fmtutil now reads *all* fmtutil.cnf files, so probably the easiest way\nis to rename the above file to $TEXMFLOCAL/web2c/fmtutil.cnf\n");
  }
    

  info("writing updmap.cfg to $TEXDIR/texmf-dist/web2c/updmap.cfg\n");
  TeXLive::TLUtils::create_updmap ($usedtlpdb,
    "$TEXDIR/texmf-dist/web2c/updmap.cfg");

  info("writing language.dat to $TEXMFSYSVAR/tex/generic/config/language.dat\n");
  TeXLive::TLUtils::create_language_dat($usedtlpdb,
    "$TEXMFSYSVAR/tex/generic/config/language.dat",
    "$TEXMFLOCAL/tex/generic/config/language-local.dat");

  info("writing language.def to $TEXMFSYSVAR/tex/generic/config/language.def\n");
  TeXLive::TLUtils::create_language_def($usedtlpdb,
    "$TEXMFSYSVAR/tex/generic/config/language.def",
    "$TEXMFLOCAL/tex/generic/config/language-local.def");

  info("writing language.dat.lua to $TEXMFSYSVAR/tex/generic/config/language.dat.lua\n");
  TeXLive::TLUtils::create_language_lua($usedtlpdb,
    "$TEXMFSYSVAR/tex/generic/config/language.dat.lua",
    "$TEXMFLOCAL/tex/generic/config/language-local.dat.lua");

  $errcount += wsystem("running", "mktexlsr",
                       $TEXMFSYSVAR, $TEXMFSYSCONFIG, "$TEXDIR/texmf-dist");

  $errcount += run_postinst_cmd("updmap-sys --nohash");

  # now work through the options if specified at all

  # letter instead of a4
  if ($vars{'option_letter'}) {
    # set paper size, but do not execute any post actions, which in this
    # case would be mktexlsr and fmtutil-sys -all; clearly premature
    # here in the installer.
    info("setting default paper size to letter:\n");
    $errcount += run_postinst_cmd("tlmgr --no-execute-actions paper letter");
  }

  # now rerun mktexlsr for updmap-sys and tlmgr paper letter updates.
  $errcount += wsystem("re-running", "mktexlsr", $TEXMFSYSVAR,$TEXMFSYSCONFIG);

  # luatex/context setup.
  if (exists($install{"context"}) && $install{"context"} == 1
      && !exists $ENV{"TEXLIVE_INSTALL_NO_CONTEXT_CACHE"}) {
    info("setting up ConTeXt cache: ");
    $errcount += run_postinst_cmd("mtxrun --generate");
  }

  # all formats option
  if ($vars{'option_fmt'}) {
    info("pre-generating all format files, be patient...\n");
    $errcount += run_postinst_cmd("fmtutil-sys $common_fmtutil_args --all");
  }

  # do path adjustments: On Windows add/remove to PATH etc,
  # on Unix set symlinks
  # for portable, this option should be unset
  # it should not be necessary to test separately for portable
  do_path_adjustments() if $vars{'option_path'};

  # now do the system integration:
  # on unix this means setting up symlinks
  # on w32 this means adding to path, settting registry values
  # on both, we run the postaction directives of the tlpdb
  # no need to test for portable or in_place:
  # the menus (or profile?) should have set the required options
  $errcount += do_tlpdb_postactions();
  
  return $errcount;
}


# Run the post installation code in the postaction tlpsrc entries.
# Return number of errors found, or zero.

sub do_tlpdb_postactions {
  info ("running package-specific postactions\n");

  # option settings already reflect portable- and in_place options.
  my $usedtlpdb = $vars{'in_place'} ? $tlpdb : $localtlpdb;
  
  foreach my $package ($usedtlpdb->list_packages) {
    TeXLive::TLUtils::do_postaction("install",
                                    $usedtlpdb->get_package($package),
                                    $vars{'option_file_assocs'},
                                    $vars{'option_menu_integration'},
                                    $vars{'option_desktop_integration'},
                                    $vars{'option_post_code'});
  }
  info ("finished with package-specific postactions\n");
  
  return 0; # xxxx errcount
}

sub do_path_adjustments {
  info ("running path adjustment actions\n");
  if (win32()) {
    TeXLive::TLUtils::w32_add_to_path($vars{'TEXDIR'}.'/bin/win32',
      $vars{'option_w32_multi_user'});
    broadcast_env();
  } else {
    TeXLive::TLUtils::add_symlinks($vars{'TEXDIR'}, $vars{'this_platform'},
      $vars{'option_sys_bin'}, $vars{'option_sys_man'},
      $vars{'option_sys_info'});
  }
  info ("finished with path adjustment actions\n");
}


# we have to adjust the texmf.cnf file to the paths set in the configuration!
sub do_texmf_cnf {
  open(TMF,"<$vars{'TEXDIR'}/texmf-dist/web2c/texmf.cnf")
      or die "$vars{'TEXDIR'}/texmf-dist/web2c/texmf.cnf not found: $!";
  my @texmfcnflines = <TMF>;
  close(TMF);

  my @changedtmf = ();  # install to disk: write only changed items

  my $yyyy = $TeXLive::TLConfig::ReleaseYear;

  # we have to find TEXMFLOCAL TEXMFSYSVAR and TEXMFHOME
  foreach my $line (@texmfcnflines) {
    if ($line =~ m/^TEXMFLOCAL/) {
      # by default TEXMFLOCAL = TEXDIR/../texmf-local, if this is the case
      # we don't have to write a new setting.
      my $deftmlocal = dirname($vars{'TEXDIR'});
      $deftmlocal .= "/texmf-local";
      if ("$vars{'TEXMFLOCAL'}" ne "$deftmlocal") {
        push @changedtmf, "TEXMFLOCAL = $vars{'TEXMFLOCAL'}\n";
      }
    } elsif ($line =~ m/^TEXMFSYSVAR/) {
      if ("$vars{'TEXMFSYSVAR'}" ne "$vars{'TEXDIR'}/texmf-var") {
        push @changedtmf, "TEXMFSYSVAR = $vars{'TEXMFSYSVAR'}\n";
      }
    } elsif ($line =~ m/^TEXMFSYSCONFIG/) {
      if ("$vars{'TEXMFSYSCONFIG'}" ne "$vars{'TEXDIR'}/texmf-config") {
        push @changedtmf, "TEXMFSYSCONFIG = $vars{'TEXMFSYSCONFIG'}\n";
      }
    } elsif ($line =~ m/^TEXMFVAR/) {
      if ($vars{"TEXMFVAR"} ne "~/.texlive$yyyy/texmf-var") {
        push @changedtmf, "TEXMFVAR = $vars{'TEXMFVAR'}\n";
      }
    } elsif ($line =~ m/^TEXMFCONFIG/) {
      if ("$vars{'TEXMFCONFIG'}" ne "~/.texlive$yyyy/texmf-config") {
        push @changedtmf, "TEXMFCONFIG = $vars{'TEXMFCONFIG'}\n";
      }
    } elsif ($line =~ m/^TEXMFHOME/) {
      if ("$vars{'TEXMFHOME'}" ne "~/texmf") {
        push @changedtmf, "TEXMFHOME = $vars{'TEXMFHOME'}\n";
      }
    } elsif ($line =~ m/^OSFONTDIR/) {
      if (win32()) {
        push @changedtmf, "OSFONTDIR = \$SystemRoot/fonts//\n";
      }
    }
  }

  if ($vars{'portable'}) {
    push @changedtmf, "ASYMPTOTE_HOME = \$TEXMFCONFIG/asymptote\n";
  }

  my ($TMF, $TMFLUA);
  # we want to write only changes to texmf.cnf
  # even for in_place installation
  $TMF = ">$vars{'TEXDIR'}/texmf.cnf";
  open(TMF, $TMF) || die "open($TMF) failed: $!";
  print TMF <<EOF;
% (Public domain.)
% This texmf.cnf file should contain only your personal changes from the
% original texmf.cnf (for example, as chosen in the installer).
%
% That is, if you need to make changes to texmf.cnf, put your custom
% settings in this file, which is .../texlive/YYYY/texmf.cnf, rather than
% the distributed file (which is .../texlive/YYYY/texmf-dist/web2c/texmf.cnf).
% And include *only* your changed values, not a copy of the whole thing!
%
EOF
  foreach (@changedtmf) {
    # avoid absolute paths for TEXDIR, use $SELFAUTOPARENT instead
    s/^(TEXMF\w+\s*=\s*)\Q$vars{'TEXDIR'}\E/$1\$SELFAUTOPARENT/;
    print TMF;
  }
  #
  # save the setting of shell_escape to the generated system texmf.cnf
  # default in texmf-dist/web2c/texmf.cnf is
  #   shell_escape = p
  # so we write that only if the user *deselected* this option
  if (!$vars{"option_write18_restricted"}) {
    print TMF <<EOF;

% Disable system commands via \\write18{...}.  See texmf-dist/web2c/texmf.cnf.
shell_escape = 0
EOF
;
  }
  close(TMF) || warn "close($TMF) failed: $!";

  $TMFLUA = ">$vars{'TEXDIR'}/texmfcnf.lua";
  open(TMFLUA, $TMFLUA) || die "open($TMFLUA) failed: $!";
    print TMFLUA <<EOF;
-- (Public domain.)
-- This texmfcnf.lua file should contain only your personal changes from the
-- original texmfcnf.lua (for example, as chosen in the installer).
--
-- That is, if you need to make changes to texmfcnf.lua, put your custom
-- settings in this file, which is .../texlive/YYYY/texmfcnf.lua, rather than
-- the distributed file (.../texlive/YYYY/texmf-dist/web2c/texmfcnf.lua).
-- And include *only* your changed values, not a copy of the whole thing!

return { 
  content = {
    variables = {
EOF
;
  foreach (@changedtmf) {
    my $luavalue = $_;
    $luavalue =~ s/^(\w+\s*=\s*)(.*)\s*$/$1\"$2\",/;
    $luavalue =~ s/\$SELFAUTOPARENT/selfautoparent:/g;
    print TMFLUA "      $luavalue\n";
  }
  print TMFLUA "    },\n";
  print TMFLUA "  },\n";
  if (!$vars{"option_write18_restricted"}) {
    print TMFLUA <<EOF;
  directives = {
       -- Disable system commands.  See texmf-dist/web2c/texmfcnf.lua
    ["system.commandmode"]       = "none",
  },
EOF
;
  }
  print TMFLUA "}\n";
  close(TMFLUA) || warn "close($TMFLUA) failed: $!";
}


sub dump_vars {
  my $filename=shift;
  my $fh;
  if (ref($filename)) {
    $fh = $filename;
  } else {
    open VARS, ">$filename";
    $fh = \*VARS;
  }
  foreach my $key (keys %vars) {
    print $fh "$key $vars{$key}\n";
  }
  close VARS if (!ref($filename));
  debug("\n%vars dumped to '$filename'.\n");
}


# Determine which platforms are supported.
sub set_platforms_supported {
  my @binaries = $tlpdb->available_architectures;
  for my $binary (@binaries) {
    unless (defined $vars{"binary_$binary"}) {
      $vars{"binary_$binary"}=0;
    }
  }
  for my $key (keys %vars) {
    ++$vars{'n_systems_available'} if ($key=~/^binary/);
  }
}

# Environment variables and default values on UNIX:
#   TEXLIVE_INSTALL_PREFIX         /usr/local/texlive   => $tex_prefix
#   TEXLIVE_INSTALL_TEXDIR         $tex_prefix/2010     => $TEXDIR
#   TEXLIVE_INSTALL_TEXMFSYSVAR    $TEXDIR/texmf-var
#   TEXLIVE_INSTALL_TEXMFSYSCONFIG $TEXDIR/texmf-config
#   TEXLIVE_INSTALL_TEXMFLOCAL     $tex_prefix/texmf-local
#   TEXLIVE_INSTALL_TEXMFHOME      '$HOME/texmf'
#   TEXLIVE_INSTALL_TEXMFVAR       ~/.texlive2010/texmf-var
#   TEXLIVE_INSTALL_TEXMFCONFIG    ~/.texlive2010/texmf-config

sub set_texlive_default_dirs {
  my $tex_prefix = $vars{'in_place'} ? abs_path($::installerdir)
                                     : getenv('TEXLIVE_INSTALL_PREFIX');
  if (win32) {
    $tex_prefix ||= getenv('SystemDrive') . '/texlive';
    # we use SystemDrive because ProgramFiles requires admin rights
    # we don't use USERPROFILE here because that will be copied back and
    # forth on roaming profiles
  } else {
    $tex_prefix ||= '/usr/local/texlive';
  }
  # for portable and in_place installation we want everything in one directory
  $vars{'TEXDIR'} = ($vars{'portable'} || $vars{'in_place'})
                     ? $tex_prefix : "$tex_prefix/$texlive_release";

  my $texmfsysvar = getenv('TEXLIVE_INSTALL_TEXMFSYSVAR');
  $texmfsysvar ||= $vars{'TEXDIR'} . '/texmf-var';
  $vars{'TEXMFSYSVAR'} = $texmfsysvar;

  my $texmfsysconfig = getenv('TEXLIVE_INSTALL_TEXMFSYSCONFIG');
  $texmfsysconfig ||= $vars{'TEXDIR'} . '/texmf-config';
  $vars{'TEXMFSYSCONFIG'}=$texmfsysconfig;

  my $texmflocal = getenv('TEXLIVE_INSTALL_TEXMFLOCAL');
  $texmflocal ||= "$tex_prefix/texmf-local";
  $vars{'TEXMFLOCAL'} = $texmflocal;

  $vars{'TEXDIR'} = $vars{'in_place'}
                    ? abs_path($::installerdir) : $vars{'TEXDIR'};

  my $texmfhome = getenv('TEXLIVE_INSTALL_TEXMFHOME');
  $texmfhome ||= "~";
  $vars{'TEXMFHOME'} = "$texmfhome/texmf";

  # use the $texmfhome value just computed for these.
  my $yyyy = $TeXLive::TLConfig::ReleaseYear;
  my $texmfvar = getenv('TEXLIVE_INSTALL_TEXMFVAR');
  $texmfvar ||= "$texmfhome/.texlive$yyyy/texmf-var";
  $vars{'TEXMFVAR'} = $texmfvar;

  my $texmfconfig = getenv('TEXLIVE_INSTALL_TEXMFCONFIG');
  $texmfconfig ||= "$texmfhome/.texlive$yyyy/texmf-config";
  $vars{'TEXMFCONFIG'} = $texmfconfig;

  # for portable installation we want everything in one directory
  if ($vars{'portable'}) {
    $vars{'TEXMFHOME'}   = "\$TEXMFLOCAL";
    $vars{'TEXMFVAR'}    = "\$TEXMFSYSVAR";
    $vars{'TEXMFCONFIG'} = "\$TEXMFSYSCONFIG";
  }
}

sub calc_depends {
  # we have to reset the install hash EVERY TIME otherwise everything will
  # always be installed since the default is scheme-full which selects
  # all packages and never deselects it
  %install=();
  my $p;
  my $a;

  # initialize the %install hash with what should be installed

  if ($vars{'selected_scheme'} ne "scheme-custom") {
    # First look for packages in the selected scheme.
    my $scheme=$tlpdb->get_package($vars{'selected_scheme'});
    if (!defined($scheme)) {
      if ($vars{'selected_scheme'}) {
        # something is written in the selected scheme but not defined, that
        # is strange, so warn and die
        die ("Scheme $vars{'selected_scheme'} not defined, vars:\n");
        dump_vars(\*STDOUT);
      }
    } else {
      for my $scheme_content ($scheme->depends) {
        $install{"$scheme_content"}=1 unless ($scheme_content=~/^collection-/);
      }
    }
  }

  # Now look for collections in the %vars hash.  These are not
  # necessarily the collections required by a scheme.  The final
  # decision is made in the collections/languages menu.
  foreach my $key (keys %vars) {
    if ($key=~/^collection-/) {
      $install{$key} = 1 if $vars{$key};
    }
  }

  # compute the list of archs to be installed
  my @archs;
  foreach (keys %vars) {
    if (m/^binary_(.*)$/ ) {
      if ($vars{$_}) { push @archs, $1; }
    }
  }

  #
  # work through the addon settings in the %vars hash
  #if ($vars{'addon_editor'}) {
  #  $install{"texworks"} = 1;
  #}

  # if programs for arch=win32 are installed we also have to install
  # tlperl.win32 which provides the "hidden" perl that will be used
  # to run all the perl scripts.
  # Furthermore we install tlgs.win32 and tlpsv.win32, too
  if (grep(/^win32$/,@archs)) {
    $install{"tlperl.win32"} = 1;
    $install{"tlgs.win32"} = 1;
    $install{"tlpsv.win32"} = 1;
  }

  # loop over all the packages until it is getting stable
  my $changed = 1;
  while ($changed) {
    # set $changed to 0
    $changed = 0;

    # collect the already selected packages
    my @pre_selected = keys %install;
    debug("initial number of installations: $#pre_selected\n");

    # loop over all the pre_selected and add them
    foreach $p (@pre_selected) {
      ddebug("pre_selected $p\n");
      my $pkg = $tlpdb->get_package($p);
      if (!defined($pkg)) {
        tlwarn("$p is mentioned somewhere but not available, disabling it.\n");
        $install{$p} = 0;
        next;
      }
      foreach my $p_dep ($tlpdb->get_package($p)->depends) {
        if ($p_dep =~ m/^(.*)\.ARCH$/) {
          my $foo = "$1";
          foreach $a (@archs) {
            $install{"$foo.$a"} = 1 if defined($tlpdb->get_package("$foo.$a"));
          }
        } elsif ($p_dep =~ m/^(.*)\.win32$/) {
          # a win32 package should *only* be installed if we are installing
          # the win32 arch
          if (grep(/^win32$/,@archs)) {
            $install{$p_dep} = 1;
          }
        } else {
          $install{$p_dep} = 1;
        }
      }
    }

    # check for newly selected packages
    my @post_selected = keys %install;
    debug("number of post installations: $#post_selected\n");

    # set repeat condition
    if ($#pre_selected != $#post_selected) {
      $changed = 1;
    }
  }

  # now do the size computation
  my $size = 0;
  foreach $p (keys %install) {
    my $tlpobj = $tlpdb->get_package($p);
    if (not(defined($tlpobj))) {
      tlwarn("$p should be installed but "
             . "is not in texlive.tlpdb; disabling.\n");
      $install{$p} = 0;
      next;
    }
    $size+=$tlpobj->docsize if $vars{'option_doc'};
    $size+=$tlpobj->srcsize if $vars{'option_src'};
    $size+=$tlpobj->runsize;
    foreach $a (@archs) {
      $size += $tlpobj->binsize->{$a} if defined($tlpobj->binsize->{$a});
    }
  }
  $vars{'total_size'} =
    sprintf "%d", ($size * $TeXLive::TLConfig::BlockSize)/1024**2;
}

sub load_tlpdb {
  my $master = $location;
  info("Loading $master/$TeXLive::TLConfig::InfraLocation/$TeXLive::TLConfig::DatabaseName\n");
  $tlpdb = TeXLive::TLPDB->new(root => $master);
  if (!defined($tlpdb)) {
    my $do_die = 1;
    # if that failed, and:
    # - we are installing from the network
    # - the location string does not contain "tlnet"
    # then we simply add "/systems/texlive/tlnet" in case someone just
    # gave an arbitrary CTAN mirror address without the full path
    if ($media eq "NET" && $location !~ m/tlnet/) {
      tlwarn("First attempt for net installation failed;\n");
      tlwarn("  repository url does not contain \"tlnet\",\n");
      tlwarn("  retrying with \"/systems/texlive/tlnet\" appended.\n");
      $location .= "/systems/texlive/tlnet";
      $master = $location;
      #
      # since we change location, we reset the error count of the
      # download object
      $::tldownload_server->enable if defined($::tldownload_server);
      #
      $tlpdb = TeXLive::TLPDB->new(root => $master);
      if (!defined($tlpdb)) {
        tlwarn("Oh well, adding tlnet did not help.\n");
        tlwarn(<<END_EXPLICIT_MIRROR);

You may want to try specifying an explicit or different CTAN mirror;
see the information and examples for the -repository option at
http://tug.org/texlive/doc/install-tl.html
(or in the output of install-tl --help).

You can also rerun the installer with -select-repository
to choose a mirror from a menu.

END_EXPLICIT_MIRROR
      } else {
        # hurray, that worked out
        info("Loading $master/$TeXLive::TLConfig::InfraLocation/$TeXLive::TLConfig::DatabaseName\n");
        $do_die = 0;
      }
    }
    #die "$0: Could not load TeX Live Database from $master, goodbye.\n"
    return 0
      if $do_die;
  }
  # set the defaults to what is specified in the tlpdb
  $vars{'option_doc'} = $tlpdb->option("install_docfiles");
  $vars{'option_src'} = $tlpdb->option("install_srcfiles");
  $vars{'option_fmt'} = $tlpdb->option("create_formats");
  $vars{'option_autobackup'} = $tlpdb->option("autobackup");
  $vars{'option_backupdir'} = $tlpdb->option("backupdir");
  $vars{'option_letter'} = defined($tlpdb->option("paper"))
                           && ($tlpdb->option("paper") eq "letter" ? 1 : 0);
  $vars{'option_desktop_integration'} = $tlpdb->option("desktop_integration");
  $vars{'option_desktop_integration'} = 1 if win32();
  # we unconditionally set the menu integration, this will be done in all
  # cases but portable use, where we sanitize it away
  $vars{'option_menu_integration'} = 1;
  $vars{'option_path'} = $tlpdb->option("path");
  $vars{'option_path'} = 0 if !defined($vars{'option_path'});
  $vars{'option_path'} = 1 if win32();
  $vars{'option_w32_multi_user'} = $tlpdb->option("w32_multi_user");
  # we have to make sure that this option is set to 0 in case
  # that a non-admin is running the installations program
  $vars{'option_w32_multi_user'} = 0 if (win32() && !admin());
  $vars{'option_file_assocs'} = $tlpdb->option("file_assocs");
  $vars{'option_post_code'} = $tlpdb->option("post_code");
  $vars{'option_sys_bin'} = $tlpdb->option("sys_bin");
  $vars{'option_sys_man'} = $tlpdb->option("sys_man");
  $vars{'option_sys_info'} = $tlpdb->option("sys_info");
  $vars{'option_adjustrepo'} = $tlpdb->option("adjustrepo");
  $vars{'option_write18_restricted'} = $tlpdb->option("write18_restricted");
  # this option is not stored in tlpdb if an existing installation is used
  $vars{'option_write18_restricted'} ||= 1;

  # check that the default scheme is actually present, otherwise switch to
  # scheme-minimal
  if (!defined($tlpdb->get_package($default_scheme))) {
    if (!defined($tlpdb->get_package("scheme-minimal"))) {
      die("Aborting, cannot find either $default_scheme or scheme_minimal");
    }
    $default_scheme = "scheme-minimal";
    $vars{'selected_scheme'} = $default_scheme;
  }
  return 1;
}

sub initialize_collections {
  foreach my $pkg ($tlpdb->list_packages) {
    my $tlpobj = $tlpdb->{'tlps'}{$pkg};
    if ($tlpobj->category eq "Collection") {
      $vars{"$pkg"}=0;
      ++$vars{'n_collections_available'};
      push (@collections_std, $pkg);
    }
  }
  my $scheme_tlpobj = $tlpdb->get_package($default_scheme);
  if (defined ($scheme_tlpobj)) {
    $vars{'n_collections_selected'}=0;
    foreach my $dependent ($scheme_tlpobj->depends) {
      if ($dependent=~/^(collection-.*)/) {
        $vars{"$1"}=1;
        ++$vars{'n_collections_selected'};
      }
    }
  }
  if ($vars{"binary_win32"}) {
    $vars{"collection-wintools"} = 1;
    ++$vars{'n_collections_selected'};
  }
}

sub set_install_platform {
  my $detected_platform=platform;
  if ($opt_custom_bin) {
    $detected_platform = "custom";
  }
  my $warn_nobin;
  my $warn_nobin_x86_64_linux;
  my $nowarn="";
  my $wp='***'; # warning prefix

  $warn_nobin="\n$wp WARNING: No binaries for your platform found.  ";
  $warn_nobin_x86_64_linux="$warn_nobin" .
      "$wp No binaries for x86_64-linux found, using i386-linux instead.\n";

  my $ret = $warn_nobin;
  if (defined $vars{"binary_$detected_platform"}) {
    $vars{"binary_$detected_platform"}=1;
    $vars{'inst_platform'}=$detected_platform;
    $ret = $nowarn;
  } elsif ($detected_platform eq 'x86_64-linux') {
    $vars{'binary_i386-linux'}=1;
    $vars{'inst_platform'}='i386-linux';
    $ret = $warn_nobin_x86_64_linux;
  } else {
    if ($opt_custom_bin) {
      $ret = "$wp Using custom binaries from $opt_custom_bin.\n";
    } else {
      $ret = $warn_nobin;
    }
  }
  foreach my $key (keys %vars) {
    if ($key=~/^binary.*/) {
       ++$vars{'n_systems_selected'} if $vars{$key}==1;
    }
  }
  return($ret);
}

sub create_profile {
  my $profilepath = shift;
  # The file "TLprofile" is created at the beginning of the
  # installation process and contains information about the current
  # setup.  The purpose is to allow non-interactive installations.
  my $fh;
  if (ref($profilepath)) {
    $fh = $profilepath;
  } else {
    open PROFILE, ">$profilepath";
    $fh = \*PROFILE;
  }
  my $tim = gmtime(time);
  print $fh "# texlive.profile written on $tim UTC\n";
  print $fh "# It will NOT be updated and reflects only the\n";
  print $fh "# installation profile at installation time.\n";
  print $fh "selected_scheme $vars{selected_scheme}\n";
  foreach my $key (sort keys %vars) {
    print $fh "$key $vars{$key}\n"
        if $key=~/^collection/ and $vars{$key}==1;
    print $fh "$key $vars{$key}\n" if $key =~ /^option_/;
    print $fh "$key $vars{$key}\n" if (($key =~ /^binary_/) && $vars{$key});
    print $fh "$key $vars{$key}\n" if $key =~ /^TEXDIR/;
    print $fh "$key $vars{$key}\n" if $key =~ /^TEXMFSYSVAR/;
    print $fh "$key $vars{$key}\n" if $key =~ /^TEXMFSYSCONFIG/;
    print $fh "$key $vars{$key}\n" if $key =~ /^TEXMFVAR/;
    print $fh "$key $vars{$key}\n" if $key =~ /^TEXMFCONFIG/;
    print $fh "$key $vars{$key}\n" if $key =~ /^TEXMFLOCAL/;
    print $fh "$key $vars{$key}\n" if $key =~ /^TEXMFHOME/;
    print $fh "$key $vars{$key}\n" if $key =~ /^in_place/;
    print $fh "$key $vars{$key}\n" if $key =~ /^portable/;
  }
  if (!ref($profilepath)) {
    close PROFILE;
  }
}

sub read_profile {
  my $profilepath = shift;
  open PROFILE, "<$profilepath"
    or die "$0: Cannot open profile $profilepath for reading.\n";
  my %pro;
  while (<PROFILE>) {
    chomp;
    next if m/^[[:space:]]*$/; # skip empty lines
    next if m/^[[:space:]]*#/; # skip comment lines
    my ($k,$v) = split (" ", $_, 2); # value might have spaces
    $pro{$k} = $v;
  }
  foreach (keys %vars) {
    # clear out collections from var
    if (m/^collection-/) { $vars{$_} = 0; }
    if (defined($pro{$_})) { $vars{$_} = $pro{$_}; }
  }
  # if a profile contains *only* the selected_scheme setting without
  # any collection, we assume that exactely that scheme should be installed
  my $coldefined = 0;
  foreach my $k (keys %pro) {
    if ($k =~ m/^collection-/) {
      $coldefined = 1;
      last;
    }
  }
  # if at least one collection has been defined return here
  return if $coldefined;
  # since no collections have been defined in the profile, we
  # set those to be installed on which the scheme depends
  my $scheme=$tlpdb->get_package($vars{'selected_scheme'});
  if (!defined($scheme)) {
    dump_vars(\*STDOUT);
    die ("Scheme $vars{selected_scheme} not defined.\n");
  }
  for my $scheme_content ($scheme->depends) {
    $vars{"$scheme_content"}=1 if ($scheme_content=~/^collection-/);
  }
}

# helper subroutine to do sanity check of options before installation
sub sanitise_options {
  # portable option overrides any system integration options
  $vars{'option_path'}                &&= !$vars{'portable'};
  $vars{'option_file_assocs'}         &&= !$vars{'portable'};
  $vars{'option_desktop_integration'} &&= !$vars{'portable'};
  $vars{'option_menu_integration'}    &&= !$vars{'portable'};
}

sub do_install_packages {
  my @what;
  foreach my $package (sort keys %install) {
    push @what, $package if ($install{$package} == 1);
  }
  # temporary unset the localtlpdb options responsible for
  # running all kind of postactions, since install_packages
  # would call them without the PATH already set up
  # we are doing this anyway in do_postinstall_actions
  $localtlpdb->option ("desktop_integration", "0");
  $localtlpdb->option ("file_assocs", "0");
  $localtlpdb->option ("post_code", "0");
  if (!install_packages($tlpdb,$media,$localtlpdb,\@what,
                        $vars{'option_src'},$vars{'option_doc'})) {
    my $profile_name = "installation.profile";
    create_profile($profile_name);
    tlwarn("Installation failed.\n");
    tlwarn("Rerunning the installer will try to restart the installation.\n");
    tlwarn("Or you can restart by running the installer with:\n");
    if (win32()) {
      tlwarn("  install-tl.bat --profile $profile_name [EXTRA-ARGS]\n");
    } else {
      tlwarn("  install-tl --profile $profile_name [EXTRA-ARGS]\n");
    }
    flushlog();
    exit(1);
  }
  $localtlpdb->option ("desktop_integration", $vars{'option_desktop_integration'} ? "1" : "0");
  $localtlpdb->option ("file_assocs", $vars{'option_file_assocs'});
  $localtlpdb->option ("post_code", $vars{'option_post_code'} ? "1" : "0");
  $localtlpdb->save;
}

# for later complete removal we want to save some options and values
# into the local tlpdb:
# - should links be set, and if yes, the destination (bin,man,info)
sub save_options_into_tlpdb {
  # if we are told to adjust the repository *and* we are *not*
  # installing from the network already, we adjust the repository
  # to the default mirror.ctan.org
  if ($vars{'option_adjustrepo'} && ($media ne 'NET')) {
    $localtlpdb->option ("location", $TeXLiveURL); 
  } else {
    $localtlpdb->option ("location", $location);
  }
  $localtlpdb->option ("autobackup", $vars{'option_autobackup'});
  $localtlpdb->option ("backupdir", $vars{'option_backupdir'});
  $localtlpdb->option ("create_formats", $vars{'option_fmt'} ? "1" : "0");
  $localtlpdb->option ("desktop_integration", $vars{'option_desktop_integration'} ? "1" : "0");
  $localtlpdb->option ("file_assocs", $vars{'option_file_assocs'});
  $localtlpdb->option ("post_code", $vars{'option_post_code'} ? "1" : "0");
  $localtlpdb->option ("sys_bin", $vars{'option_sys_bin'});
  $localtlpdb->option ("sys_info", $vars{'option_sys_info'});
  $localtlpdb->option ("sys_man", $vars{'option_sys_man'});
  $localtlpdb->option ("install_docfiles", $vars{'option_doc'} ? "1" : "0");
  $localtlpdb->option ("install_srcfiles", $vars{'option_src'} ? "1" : "0");
  $localtlpdb->option ("w32_multi_user", $vars{'option_w32_multi_user'} ? "1" : "0");
  my @archs;
  foreach (keys %vars) {
    if (m/^binary_(.*)$/ ) {
      if ($vars{$_}) { push @archs, $1; }
    }
  }
  if ($opt_custom_bin) {
    push @archs, "custom";
  }

  # only if we forced the platform we do save this option into the tlpdb
  if (defined($opt_force_arch)) {
    $localtlpdb->setting ("platform", $::_platform_);
  }
  $localtlpdb->setting("available_architectures", @archs);
  $localtlpdb->save() unless $vars{'in_place'};
}

sub import_settings_from_old_tlpdb {
  my $dn = shift;
  my $tlpdboldpath = "$dn/$TeXLive::TLConfig::InfraLocation/$TeXLive::TLConfig::DatabaseName";
  my $previoustlpdb;
  if (-r $tlpdboldpath) {
    # we found an old installation, so read that one in and save
    # the list installed collections into an array.
    info ("Trying to load old TeX Live Database,\n");
    $previoustlpdb = TeXLive::TLPDB->new(root => $dn);
    if ($previoustlpdb) {
      info ("Importing settings from old installation in $dn\n");
    } else {
      tlwarn ("Cannot load old TLPDB, continuing with normal installation.\n");
      return;
    }
  } else {
    return;
  }
  ############# OLD CODE ###################
  # in former times we sometimes didn't change from scheme-full
  # to scheme-custom when deselecting some collections
  # this is fixed now.
  #
  # # first import the collections
  # # since the scheme is not the final word we select scheme-custom here
  # # and then set the single collections by hand
  # $vars{'selected_scheme'} = "scheme-custom";
  # $vars{'n_collections_selected'} = 0;
  # # remove the selection of all collections
  # foreach my $entry (keys %vars) {
  #   if ($entry=~/^(collection-.*)/) {
  #     $vars{"$1"}=0;
  #   }
  # }
  # for my $c ($previoustlpdb->collections) {
  #   my $tlpobj = $tlpdb->get_package($c);
  #   if ($tlpobj) {
  #     $vars{$c} = 1;
  #     ++$vars{'n_collections_selected'};
  #   }
  # }
  ############ END OF OLD CODE ############

  ############ NEW CODE ###################
  # we simply go through all installed schemes, install
  # all depending collections
  # if we find scheme-full we use this as 'selected_scheme'
  # otherwise we use 'scheme_custom' as we don't know
  # and there is no total order on the schemes.
  #
  # we cannot use select_scheme from tlmgr.pl, as this one clears
  # previous selctions (hmm :-(
  $vars{'selected_scheme'} = "scheme-custom";
  $vars{'n_collections_selected'} = 0;
  # remove the selection of all collections
  foreach my $entry (keys %vars) {
    if ($entry=~/^(collection-.*)/) {
      $vars{"$1"}=0;
    }
  }
  # now go over all the schemes *AND* collections and select them
  foreach my $s ($previoustlpdb->schemes) {
    my $tlpobj = $tlpdb->get_package($s);
    if ($tlpobj) {
      foreach my $e ($tlpobj->depends) {
        if ($e =~ /^(collection-.*)/) {
          # do not add collections multiple times
          if (!$vars{$e}) {
            $vars{$e} = 1;
            ++$vars{'n_collections_selected'};
          }
        }
      }
    }
  }
  # Now do the same for collections:
  for my $c ($previoustlpdb->collections) {
    my $tlpobj = $tlpdb->get_package($c);
    if ($tlpobj) {
      if (!$vars{$c}) {
        $vars{$c} = 1;
        ++$vars{'n_collections_selected'};
      }
    }
  }
  ########### END NEW CODE #############


  # now take over the path
  my $oldroot = $previoustlpdb->root;
  my $newroot = abs_path("$oldroot/..") . "/$texlive_release";
  $vars{'TEXDIR'} = $newroot;
  $vars{'TEXMFSYSVAR'} = "$newroot/texmf-var";
  $vars{'TEXMFSYSCONFIG'} = "$newroot/texmf-config";
  # only TEXMFLOCAL is treated differently, we use what is found by kpsewhich
  # in 2008 and onward this is defined as
  # TEXMFLOCAL = $SELFAUTOPARENT/../texmf-local
  # so kpsewhich -var-value=TEXMFLOCAL returns
  # ..../2008/../texmf-local
  # TODO TODO TODO
  chomp (my $tml = `kpsewhich -var-value=TEXMFLOCAL`);
  $tml = abs_path($tml);
  $vars{'TEXMFLOCAL'} = $tml;
  #
  # now for the settings
  # set the defaults to what is specified in the tlpdb
  $vars{'option_doc'} =
    $previoustlpdb->option_pkg("00texlive.installation",
                               "install_docfiles");
  $vars{'option_src'} =
    $previoustlpdb->option_pkg("00texlive.installation",
                               "install_srcfiles");
  $vars{'option_fmt'} =
    $previoustlpdb->option_pkg("00texlive.installation",
                               "create_formats");
  $vars{'option_desktop_integration'} = 1 if win32();
  $vars{'option_menu_integration'} = 1 if win32();
  $vars{'option_path'} =
    $previoustlpdb->option_pkg("00texlive.installation",
                               "path");
  $vars{'option_path'} = 0 if !defined($vars{'option_path'});
  $vars{'option_path'} = 1 if win32();
  $vars{'option_sys_bin'} =
    $previoustlpdb->option_pkg("00texlive.installation",
                               "sys_bin");
  $vars{'option_sys_man'} =
    $previoustlpdb->option_pkg("00texlive.installation",
                               "sys_man");
  $vars{'sys_info'} =
    $previoustlpdb->option_pkg("00texlive.installation",
                               "sys_info");
  #
  # import the set of selected architectures
  my @aar = $previoustlpdb->setting_pkg("00texlive.installation",
                                        "available_architectures");
  if (@aar) {
    for my $b ($tlpdb->available_architectures) {
      $vars{"binary_$b"} = member( $b, @aar );
    }
    $vars{'n_systems_available'} = 0;
    for my $key (keys %vars) {
      ++$vars{'n_systems_available'} if ($key=~/^binary/);
    }
  }
  #
  # try to import paper settings
  my $xdvi_paper;
  if (!win32()) {
    $xdvi_paper = TeXLive::TLPaper::get_paper("xdvi");
  }
  my $pdftex_paper = TeXLive::TLPaper::get_paper("pdftex");
  my $dvips_paper = TeXLive::TLPaper::get_paper("dvips");
  my $dvipdfmx_paper = TeXLive::TLPaper::get_paper("dvipdfmx");
  my $context_paper;
  if (defined($previoustlpdb->get_package("context"))) {
    $context_paper = TeXLive::TLPaper::get_paper("context");
  }
  my $common_paper = "";
  if (defined($xdvi_paper)) {
    $common_paper = $xdvi_paper;
  }
  $common_paper = 
    ($common_paper ne $context_paper ? "no-agree-on-paper" : $common_paper)
      if (defined($context_paper));
  $common_paper = 
    ($common_paper ne $pdftex_paper ? "no-agree-on-paper" : $common_paper)
      if (defined($pdftex_paper));
  $common_paper = 
    ($common_paper ne $dvips_paper ? "no-agree-on-paper" : $common_paper)
      if (defined($dvips_paper));
  $common_paper = 
    ($common_paper ne $dvipdfmx_paper ? "no-agree-on-paper" : $common_paper)
      if (defined($dvipdfmx_paper));
  if ($common_paper eq "no-agree-on-paper") {
    tlwarn("Previous installation uses different paper settings.\n");
    tlwarn("You will need to select your preferred paper sizes manually.\n\n");
  } else {
    if ($common_paper eq "letter") {
      $vars{'option_letter'} = 1;
    } elsif ($common_paper eq "a4") {
      # do nothing
    } else {
      tlwarn("Previous installation has common paper setting of: $common_paper\n");
      tlwarn("After installation has finished, you will need\n");
      tlwarn("  to redo this setting by running:\n");
    }
  }
}

# do everything to select a scheme
#
sub select_scheme {
  my $s = shift;
  # set the selected scheme to $s
  $vars{'selected_scheme'} = $s;
  # if we are working on scheme-custom simply return
  return if ($s eq "scheme-custom");
  # remove the selection of all collections
  foreach my $entry (keys %vars) {
    if ($entry=~/^(collection-.*)/) {
      $vars{"$1"}=0;
    }
  }
  # select the collections belonging to the scheme
  my $scheme_tlpobj = $tlpdb->get_package($s);
  if (defined ($scheme_tlpobj)) {
    $vars{'n_collections_selected'}=0;
    foreach my $dependent ($scheme_tlpobj->depends) {
      if ($dependent=~/^(collection-.*)/) {
        $vars{"$1"}=1;
        ++$vars{'n_collections_selected'};
      }
    }
  }
  # we have first set all collection-* keys to zero and than
  # set to 1 only those which are required by the scheme
  # since now scheme asks for collection-wintools we set its vars value
  # to 1 in case we are installing win32 binaries
  if ($vars{"binary_win32"}) {
    $vars{"collection-wintools"} = 1;
    ++$vars{'n_collections_selected'};
  }
  # for good measure, update the deps
  calc_depends();
}

# try to give a decent order of schemes, but be so general that
# if we change names of schemes nothing bad happnes (like forgetting one)
sub schemes_ordered_for_presentation {
  my @scheme_order;
  my %schemes_shown;
  for my $s ($tlpdb->schemes) { $schemes_shown{$s} = 0 ; }
  # first try the size-name-schemes in decreasing order
  for my $sn (qw/full medium small basic minimal/) {
    if (defined($schemes_shown{"scheme-$sn"})) {
      push @scheme_order, "scheme-$sn";
      $schemes_shown{"scheme-$sn"} = 1;
    }
  }
  # now push all the other schemes if they are there and not already shown
  for my $s (sort keys %schemes_shown) {
    push @scheme_order, $s if !$schemes_shown{$s};
  }
  return @scheme_order;
}

sub update_numbers {
  $vars{'n_collections_available'}=0;
  $vars{'n_collections_selected'} = 0;
  $vars{'n_systems_available'} = 0;
  $vars{'n_systems_selected'} = 0;
  foreach my $key (keys %vars) {
    if ($key =~ /^binary/) {
      ++$vars{'n_systems_available'};
      ++$vars{'n_systems_selected'} if $vars{$key} == 1;
    }
    if ($key =~ /^collection-/) {
      ++$vars{'n_collections_available'};
      ++$vars{'n_collections_selected'} if $vars{$key} == 1;
    }
  }
}

sub flushlog {
  my $fh;
  my $logfile = "install-tl.log";
  if (open (LOG, ">$logfile")) {
    my $pwd = Cwd::getcwd();
    $logfile = "$pwd/$logfile";
    print "$0: Writing log in current directory: $logfile\n";
    $fh = \*LOG;
  } else {
    $fh = \*STDERR;
    print "$0: Could not write to $logfile, so flushing messages to stderr.\n";
  }

  foreach my $l (@::LOGLINES) {
    print $fh $l;
  }
}

sub do_cleanup {
  # now open the log file and write out the log lines if needed.
  # the user could have given the -logfile option in which case all the
  # stuff is already dumped to it and $::LOGFILE defined. So do not
  # redefine it.
  if (!defined($::LOGFILE)) {
    if (open(LOGF,">$vars{'TEXDIR'}/install-tl.log")) {
      $::LOGFILE = \*LOGF;
      foreach my $line(@::LOGLINES) {
        print $::LOGFILE "$line";
      }
    } else {
      tlwarn("$0: Cannot create log file $vars{'TEXDIR'}/install-tl.log: $!\n"
             . "Not writing out log lines.\n");
    }
  }

  # remove temporary files from TEXDIR/temp
  if (($media eq "local_compressed") or ($media eq "NET")) {
    debug("Remove temporary downloaded containers...\n");
    rmtree("$vars{'TEXDIR'}/temp") if (-d "$vars{'TEXDIR'}/temp");
  }

  # write the profile out
  if ($vars{'in_place'}) {
    create_profile("$vars{'TEXDIR'}/texlive.profile");
    debug("Profile written to $vars{'TEXDIR'}/texlive.profile\n");
  } else {
    create_profile("$vars{'TEXDIR'}/$InfraLocation/texlive.profile");
    debug("Profile written to $vars{'TEXDIR'}/$InfraLocation/texlive.profile\n");
  }
  # Close log file if present
  close($::LOGFILE) if (defined($::LOGFILE));
    if (defined($::LOGFILENAME) and (-e $::LOGFILENAME)) {
      print "Logfile: $::LOGFILENAME\n";
    } elsif (-e "$vars{'TEXDIR'}/install-tl.log") {
      print "Logfile: $vars{'TEXDIR'}/install-tl.log\n";
    } else {
      print "No logfile\n";
  }
}


# Return the basic welcome message.

sub welcome {
  my $welcome = <<"EOF";

 See
   $::vars{'TEXDIR'}/index.html
 for links to documentation.  The TeX Live web site
 contains updates and corrections: http://tug.org/texlive.

 TeX Live is a joint project of the TeX user groups around the world;
 please consider supporting it by joining the group best for you. The
 list of user groups is on the web at http://tug.org/usergroups.html.

 Welcome to TeX Live!

EOF
  return $welcome;
}


# The same welcome message as above but with hints about C<PATH>,
# C<MANPATH>, and C<INFOPATH>.

sub welcome_paths {
  my $welcome = welcome ();

  # ugly, remove welcome msg; better than repeating the whole text, though.
  $welcome =~ s/\n Welcome to TeX Live!\n//;

  $welcome .= <<"EOF";
 Add $::vars{'TEXDIR'}/texmf-dist/doc/info to INFOPATH.
 Add $::vars{'TEXDIR'}/texmf-dist/doc/man to MANPATH
   (if not dynamically found).
EOF

  $welcome .= <<"EOF";

 Most importantly, add $::vars{'TEXDIR'}/bin/$::vars{'this_platform'}
 to your PATH for current and future sessions.
EOF

  unless ($ENV{"TEXLIVE_INSTALL_ENV_NOCHECK"}) {
    # check for tex-related envvars.
    my $texenvs = "";
    for my $evar (sort keys %origenv) {
      next if $evar =~ /^(_
                          |.*PWD
                          |GENDOCS_TEMPLATE_DIR|PATH|SHELLOPTS
                         )$/x; # don't worry about these
      if ("$evar $origenv{$evar}" =~ /tex/i) { # check both key and value
        $texenvs .= "    $evar=$origenv{$evar}\n";
      }
    }
    if ($texenvs) {
      $welcome .= <<"EOF";

 ----------------------------------------------------------------------
 The following environment variables contain the string "tex"
 (case-independent).  If you're doing anything but adding personal
 directories to the system paths, they may well cause trouble somewhere
 while running TeX.  If you encounter problems, try unsetting them.
 Please ignore spurious matches unrelated to TeX.

$texenvs ----------------------------------------------------------------------
EOF
    }
  }

  $welcome .= <<"EOF";

 Welcome to TeX Live!
EOF

  return $welcome;
}


# remember the warnings issued
sub install_warnlines_hook {
  push @::warn_hook, sub { push @::WARNLINES, @_; };
}

# a summary of warnings if there were any
sub warnings_summary {
  return '' unless @::WARNLINES;
  my $summary = <<EOF;

Summary of warning messages during installation:
EOF
  $summary .= join ("", map { "  $_" } @::WARNLINES); # indent each warning
  $summary .= "\n";  # extra blank line
  return $summary;
}



# some helper functions
# 
sub select_collections {
  my $varref = shift;
  foreach (@_) {
    $varref->{$_} = 1;
  }
}

sub deselect_collections {
  my $varref = shift;
  foreach (@_) {
    $varref->{$_} = 0;
  }
}


__END__

=head1 NAME

install-tl - TeX Live cross-platform installer

=head1 SYNOPSIS

install-tl [I<option>]...

install-tl.bat [I<option>]...

=head1 DESCRIPTION

This installer creates a runnable TeX Live installation from various
media, including over the network.  The installer works across all
platforms supported by TeX Live.  For information on initially
downloading the TeX Live, see L<http://tug.org/texlive/acquire.html>.

The basic idea of TeX Live installation is to choose one of the
top-level I<schemes>, each of which is defined as a different set of
I<collections> and I<packages>, where a collection is a set of packages,
and a package is what contains actual files.

Within the installer, you can choose a scheme, and further customize the
set of collections to install, but not the set of the packages.  To do
that, use C<tlmgr> (reference below) after the initial installation is
completely.

The default is C<scheme-full>, to install everything, and this is highly
recommended.

=head1 REFERENCES

Post-installation configuration, package updates, and much more, are
handled through B<tlmgr>(1), the TeX Live Manager
(L<http://tug.org/texlive/tlmgr.html>).

The most up-to-date version of this documentation is on the Internet at
L<http://tug.org/texlive/doc/install-tl.html>.

For the full documentation of TeX Live, see
L<http://tug.org/texlive/doc>.

=head1 OPTIONS

As usual, all options can be specified in any order, and with either a
leading C<-> or C<-->.  An argument value can be separated from its
option by either a space or C<=>.

=over 4

=item B<-gui> [[=]I<module>]

If no I<module> is given starts the C<perltk> (see below) GUI installer.

If I<module> is given loads the given installer module. Currently the
following modules are supported:

=over 8

=item C<text>

The text mode user interface (default on Unix systems).  Same as the
C<-no-gui> option.

=item C<wizard>

The wizard mode user interface (default on Windows), asking only minimal
questions before installing all of TeX Live.

=item C<perltk>

The expert GUI installer, providing access to more options.  
Can also be invoked on Windows by running C<install-tl-advanced.bat>.

=back

The C<perltk> and C<wizard> modules, and thus also when calling with a
bare C<-gui> (without I<module>), requires the Perl/Tk module
(L<http://tug.org/texlive/distro.html#perltk>); if Perl/Tk is not
available, installation continues in text mode.


=item B<-no-gui>

Use the text mode installer (default except on Windows).

=for comment Keep language list in sync with tlmgr.

=item B<-lang> I<llcode>

By default, the GUI tries to deduce your language from the environment
(on Windows via the registry, on Unix via C<LC_MESSAGES>). If that fails
you can select a different language by giving this option with a
language code (based on ISO 639-1).  Currently supported (but not
necessarily completely translated) are: English (en, default), Czech
(cs), German (de), French (fr), Italian (it), Japanese (ja), Dutch (nl),
Polish (pl), Brazilian Portuguese (pt_BR), Russian (ru), Slovak (sk),
Slovenian (sl), Serbian (sr), Ukrainian (uk), Vietnamese (vi),
simplified Chinese (zh_CN), and traditional Chinese (zh_TW).

=item B<-repository> I<url|path>

Specify the package repository to be used as the source of the
installation, either a local directory via C</path/to/directory> or a
C<file:/> url, or a network location via a C<http://> or C<ftp://> url.
(No other protocols are supported.)

The default is to pick a mirror automatically, using
L<http://mirror.ctan.org/systems/texlive/tlnet>; the chosen mirror is
used for the entire download.  You can use the special argument C<ctan>
as an abbreviation for this.  See L<http://ctan.org> for more about CTAN
and its mirrors.

If the repository is on the network, trailing C</> characters and/or
trailing C</tlpkg> and C</archive> components are ignored.  For example,
you could choose a particular CTAN mirror with something like this:

  -repository http://ctan.example.org/its/ctan/dir/systems/texlive/tlnet

Of course a real hostname and its particular top-level CTAN path
have to be specified.  The list of CTAN mirrors is available at
L<http://ctan.org/mirrors>.

If the repository is local, the installation type (compressed or live) is
automatically determined, by checking for the presence of a
C<archive> directory relative to the root.  Compressed is
preferred if both are available, since it is faster.  Here's an example
of using a local directory:

  -repository /local/TL/repository

After installation is complete, you can use that installation as the
repository for another installation.  If you chose to install less than
the full scheme containing all packages, the list of available schemes
will be adjusted accordingly.

For backward compatibility and convenience, C<--location> and C<--repo>
are accepted as aliases for this option.

=item B<-select-repository>

This option allows manual selection of a mirror from the current list of
active CTAN mirrors.  This option is supported in all installer modes
(text, wizard, perltk), and will also offer to install from local media
if available, or from a repository specified on the command line (see
above).  It's useful when the (default) automatic redirection does not
choose a good host for you.

=item B<-all-options>

Normally options not relevant to the current platform are not shown
(i.e., when running on Unix, Windows-specific options are omitted).
Giving this command line option allows configuring settings in the
final C<texlive.tlpdb> that do not have any immediate effect.

=item B<-custom-bin> I<path>

If you have built your own set of TeX Live binaries (perhaps because
your platform was not supported by TeX Live out of the box), this option
allows you to specify the I<path> to a directory where the binaries for
the current system are present.  The installation will continue as
usual, but at the end all files from I<path> are copied over to
C<bin/custom/> under your installation directory and this C<bin/custom/>
directory is what will be added to the path for the post-install
actions.  (By the way, for information on building TeX Live, see
L<http://tug.org/texlive/build.html>).

=item B<-debug-translation>

In GUI mode, this switch makes C<tlmgr> report any missing, or more
likely untranslated, messages to standard error.  Helpful for
translators to see what remains to be done.

=item B<-force-platform> I<platform>

Instead of auto-detecting the current platform, use I<platform>.
Binaries for this platform must be present and they must actually be
runnable, or installation will fail.  C<-force-arch> is a synonym.

=item B<-help>, B<--help>, B<-?>

Display this help and exit (on the web via
L<http://tug.org/texlive/doc/install-tl.html>).  Sometimes the
C<perldoc> and/or C<PAGER> programs on the system have problems,
possibly resulting in control characters being literally output.  This
can't always be detected, but you can set the C<NOPERLDOC> environment
variable and C<perldoc> will not be used.

=item B<-in-place>

This is a quick-and-dirty installation option in case you already have
an rsync or svn checkout of TeX Live.  It will use the checkout as-is
and will just do the necessary post-install.  Be warned that the file
C<tlpkg/texlive.tlpdb> may be rewritten, that removal has to be done
manually, and that the only realistic way to maintain this installation
is to redo it from time to time.  This option is not available via the
installer interfaces.  USE AT YOUR OWN RISK.

=item B<-logfile> I<file>

Write both all messages (informational, debugging, warnings) to I<file>,
in addition to standard output or standard error.

If this option is not given, the installer will create a log file
in the root of the writable installation tree,
for example, C</usr/local/texlive/YYYY/install-tl.log> for the I<YYYY>
release.

=item B<-no-cls>

(only for text mode installer) do not clear the screen when entering
a new menu (for debugging purposes).

=item B<-non-admin>

For Windows only: configure for the current user, not for all users.

=item B<--persistent-downloads>

=item B<--no-persistent-downloads>

For network installs, activating this option makes the installer try to
set up a persistent connection using the C<Net::LWP> Perl module.  This
opens only one connection between your computer and the server per
session and reuses it, instead of initiating a new download for each
package, which typically yields a significant speed-up.

This option is turned on by default, and the installation program will
fall back to using C<wget> if this is not possible.  To disable usage of
LWP and persistent connections, use C<--no-persistent-downloads>.

=item B<-portable>

Install for portable use, e.g., on a USB stick.  Also selectable from
within the perltk and text installers.

=item B<-print-platform>

Print the TeX Live identifier for the detected platform
(hardware/operating system) combination to standard output, and exit.
C<-print-arch> is a synonym.

=item B<-profile> I<profile>

Load the file I<profile> and do the installation with no user
interaction, that is, a batch (unattended) install.

A I<profile> file contains all the values needed to perform an
installation.  After a normal installation has finished, a profile for
that exact installation is written to the file
DEST/tlpkg/texlive.profile.  That file can be given as the argument to
C<-profile> to redo the exact same installation on a different system,
for example.  Alternatively, you can use a custom profile, most easily
created by starting from a generated one and changing values, or an
empty file, which will take all the defaults.

Normally a profile has to specify the value C<1> for each collection to
be installed, even if the scheme is specified.  This follows from the
logic of the installer in that you can first select a scheme and then
change the collections being installed.  But for convenience there is an
exception to this within profiles: If the profile contains a variable
for C<selected_scheme> and I<no> collection variables at all are defined
in the profile, then the collections which the specified scheme requires
are installed.

Thus, a line C<selected_scheme scheme-medium> together with the
definitions of the installation directories (C<TEXDIR>, C<TEXMFHOME>,
C<TEXMFLOCAL>, C<TEXMFSYSCONFIG>, C<TEXMFSYSVAR>) suffices to install
the medium scheme with all default options.

=item B<-q>

Omit normal informational messages.

=item B<-scheme> I<scheme>

Schemes are the highest level of package grouping in TeX Live; the
default is to use the C<full> scheme, which includes everything.  This
option overrides that default.  You can change the scheme again before
the actual installation with the usual menu.  The I<scheme> argument may
optionally have a prefix C<scheme->.  The list of supported scheme names
depends on what your package repository provides; see the interactive
menu list.

=item B<-v>

Include verbose debugging messages; repeat for maximum debugging, as in
C<-v -v>.  (Further repeats are accepted but ignored.)

=item B<-version>, B<--version>

Output version information and exit.  If C<-v> has also been given the
revisions of the used modules are reported, too.

=back


=head1 ENVIRONMENT VARIABLES

For ease in scripting and debugging, C<install-tl> will look for the
following environment variables.  They are not of interest in normal
user installations.

=over 4

=item C<TEXLIVE_INSTALL_ENV_NOCHECK>

Omit the check for environment variables containing the string C<tex>.
People developing TeX-related software are likely to have many such
variables.

=item C<TEXLIVE_INSTALL_NO_CONTEXT_CACHE>

Omit creating the ConTeXt cache.  This is useful for redistributors.

=item C<TEXLIVE_INSTALL_PREFIX>

=item C<TEXLIVE_INSTALL_TEXDIR>

=item C<TEXLIVE_INSTALL_TEXMFCONFIG>

=item C<TEXLIVE_INSTALL_TEXMFHOME>

=item C<TEXLIVE_INSTALL_TEXMFLOCAL>

=item C<TEXLIVE_INSTALL_TEXMFSYSCONFIG>

=item C<TEXLIVE_INSTALL_TEXMFSYSVAR>

=item C<TEXLIVE_INSTALL_TEXMFVAR>

Specify the respective directories.  C<TEXLIVE_INSTALL_PREFIX> defaults
to C</usr/local/texlive>, while C<TEXLIVE_INSTALL_TEXDIR> defaults to
the release directory within that prefix, e.g.,
C</usr/local/texlive/2014>.  All the defaults can be seen by running the
installer interactively and then typing C<D> for the directory menu.

=item C<NOPERLDOC>

Don't try to run the C<--help> message through C<perldoc>.

=back


=head1 AUTHORS AND COPYRIGHT

This script and its documentation were written for the TeX Live
distribution (L<http://tug.org/texlive>) and both are licensed under the
GNU General Public License Version 2 or later.

=cut

### Local Variables:
### perl-indent-level: 2
### tab-width: 2
### indent-tabs-mode: nil
### End:
# vim:set tabstop=2 expandtab: #
