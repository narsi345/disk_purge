#!/usr/local/bin/perl
use warnings;
use YAML::Tiny;
use Getopt::Long;
use File::stat;
use Config::Tiny;

my $app_config_path = '/usr/local/conf/disk_purge/disk_purge.conf';
my $app_conf = Config::Tiny->read($app_config_path);
my $hostgroup = $app_conf->{global}->{hostgroup};
my $minimum_age = $app_conf->{global}->{minimum_age};
$minimum_age = 2 if(!defined $minimum_age || $minimum_age eq '');
my $config_path = '/usr/local/conf/disk_purge/agent.yml';
my ($config, $verbose, @target, $help, $dryrun, $force);
my $minimum_limit = '100m'; #100Mb
my %opt_config;
my %dir_list;

GetOptions(
    "c|config=s"  => \$config_path,
    "t|target=s"  => \@target,
    "d|drydun"    => \$dryrun,
    "f|force"     => \$force,
    "v|verbose"   => \$verbose,
    "h|help"      => \$help,
);

if($help) {
  usage();
  exit;
}

# should be executed as root
if($> > 0) {
  print "Execute using sudo\n";
  exit 1;
}

if(scalar @target > 0) {
  foreach my $setting (@target) {
    my @values = split(':', $setting);
    $dir_list{$values[0]} = $values[1];
  }
} else {
  my $yaml = YAML::Tiny->read($config_path) or die "can't open config file";
  $config = $yaml->[0];
  %target_list = ($hostgroup eq ''  || scalar keys %{$config->{$hostgroup}} == 0) ? %{$config->{common}} : (%{$config->{common}},%{$config->{$hostgroup}});
}


while(($dir_path, $hard_limit) = each(%target_list)) {
  if($dir_path =~ m/\*/) {
    my $spos = index($dir_path, '*');
    my $be = substr($dir_path, $spos-1, 1);
    my $predir = substr($dir_path, 0, $spos);
    my $prefix = '';
    my $postfix = '';

    # pre part of wildcard
    if($be ne '/') {
      my @dirs = split('/', $predir);
      $prefix = $dirs[scalar @dirs - 1];
      # to see if dir path is relative path
      $first_field = $dirs[0];
      
      splice(@dirs, -1);
      splice(@dirs, 0, 1);

      $predir = $first_field . '/' . join('/', @dirs) . '/';
    }

    my $postdir = substr($dir_path, $spos+1);
    
    # post part of wildcard
    if($postdir ne '') {
      my $ae = substr($postdir, 0, 1);
      if($ae ne '/') {
        my @dirs = split('/', $postdir);
        $postfix = $dirs[0];
        if(scalar @dirs > 1) {
          splice(@dirs, 0, 1);
          $postdir = '/' . join('/', @dirs);
        } else {
          $postdir = '';
        }
      }
    }

    if(! -d $predir) {
      print "$predir doesn't exist";
    } else {
      opendir(my $dh, $predir);
      while(my $fn = readdir $dh) {
        next if($fn =~ m/^\./);
        next if($prefix ne '' && $fn !~ /^$prefix/);
        next if($postfix ne '' && $fn !~ /$postfix$/);
        my $full_path = $predir.$fn.$postdir;
        next if(! -e $full_path);
        $dir_list{$full_path} = $hard_limit;
      }
    }

  } else {
    $dir_list{$dir_path} = $hard_limit;

  }
}

while(($dir_path, $hard_limit) = each(%dir_list)) {
  my %flist;

  # convert limit size to byte (1m -> 1,000,000 byte) 
  $limit = str2num($hard_limit);
  next if($limit == 0);
 
  if($limit < str2num($minimum_limit) && !$force) {
    print "hard limit($hard_limit) should be greater than $minimum_limit, use --force\n";
    next;
  }

  if(! -d $dir_path) {
    check_file($limit, $dir_path) if(-e $dir_path);
  } else {
    $dir_size = check_dir($dir_path, \%flist);
    if($dir_size > $limit) {
      my $size = cleanup($limit, $dir_size, \%flist);
      verbose("$dir_path: " . num2str($size));
    } else {
      verbose("$dir_path: " . num2str($dir_size));
    }
  }
}

sub check_dir {
  my ($dir, $flist) = @_;
  my $dsize = 0;

  opendir(DIR, $dir) || die "can't open $dir";
  while(my $entry = readdir(DIR)) {
    $fpath = "$dir/$entry";
    next if(! -f $fpath);

    my $fstat = stat($fpath);
    my $size = $fstat->size;
    my $mtime = $fstat->mtime;
    my %finfo = (
          'path' => $fpath,
          'size' => $size,
    );

    # minus 1 if same key(mtime) exists in hash table
    while(1) {
      if(exists $flist->{$mtime}) {
        $mtime--;
      } else {
        $flist->{$mtime} = \%finfo;
        last;
      }
    }

    $dsize += $size;
  }

  # check if target directory is  or /root/

  return $dsize;
}

sub check_file {
  my ($limit, $target_file) = @_;
  my $f_size = -s $target_file;
  if($f_size > $limit) {
    my $output = `sudo lsof $target_file 2> /dev/null`;
    if($? == 0) {
      verbose("[skip] " . $target_file . ": opened and used by other process");
    } else {
      unlink $target_file if(!$dryrun);
      verbose($target_file . "(" . num2str($f_size) . ") deleted");
    }
  }
}

sub cleanup {
  my ($limit, $size, $flist) = @_;
  my $sum = 0;
  my $soft_limit = int($limit * 1);
  
  #Miminum file mtime to be able to delete
  my $minimum_mtime = time() - ($minimum_age * 24 * 60 * 60); 

  #print "Limit: $limit, 90%: $soft_limit\n";
  foreach my $key (sort keys %$flist) {
    #print "path: $flist->{$key}->{'path'}, key: $key, size: $flist->{$key}->{'size'} \n";
    if($flist->{$key}->{'size'} > 0 && $minimum_mtime > $key) {
      #check if the file is opened and used for other processes
      my $output = `sudo lsof $flist->{$key}->{'path'} 2> /dev/null`;
      if($? == 0) {
        verbose("[skip] " . $flist->{$key}->{'path'} . ": opened and used by other process");
      } else {
        unlink $flist->{$key}->{'path'} if(!$dryrun);
        $size -= $flist->{$key}->{'size'};
        verbose($flist->{$key}->{'path'} . "(" . num2str($flist->{$key}->{'size'}) . ") deleted");
      }
    }

    last if($soft_limit > $size) 

  }
  #print "dir_size: $size, deleted: $sum\n";
  return $size;
}

sub str2num {
  my($str) = @_;
  if(defined $str) {
    $str =~ m/([0-9\.]+)([gGmM])/;
    $str1 = $1;
    $str2 = $2;
    if($str2 eq 'g' || $str2 eq 'G') {
      $number = $str1 * 1024 * 1024 * 1024;
    } elsif($str2 eq 'm' || $str2 eq 'M') {
      $number = $str1 * 1024 * 1024;
    } else {
      $number = $str1;
    }

    return int($number);
  } else {
    return 0;
  }
}

sub num2str {
  my($number) = @_;
  foreach('b','kb','mb','gb') {
    return sprintf("%.2f", $number)."$_" if $number < 1024;
    $number /= 1024;
  }
}

sub verbose {
  my($str) = @_;
#  printf("| Dir: %-60s |\n", $str) if($verbose);
  printf("%s\n", $str) if($verbose || $dryrun);
}

sub fuser {
  my($file) = @_;
  my $output = `sudo fuser $file`;

}

sub usage {
  printf "    %-15s %s\n", "-c/--config", "config  file";
  printf "    %-15s %s\n", "-t/--target", "Without config file, target and limit size can be specified using this option";
  printf "    %-15s %s\n", "-d/--dryrun", "Dryrun cleanup script. Show what files will be deleted";
  printf "    %-15s %s\n", "-f/--force",  "For directory less than 100mb";
  printf "    %-15s %s\n", "-v/--verbose","Show what files are deleted";
  printf "    %-15s %s\n", "-h/--help",   "usage";
}
