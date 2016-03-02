# disk_purge
An agent to purge directories on Linux systems as a supplement to  log_rotation


As a cron remediation for disk full issues.

Background:
Disk full issue still happens from time to time even though we already have log rotation for each application. These log rotations are configured by application level config or additional log rotation pkg we made and they basically rotate log files based on age of files or the number of files in the log directory. Unfortunately, we can't prevent disk full issue using current log rotations because log directory size is not limited and could grow up until reaching 100% of disk partition for some reason such as more log entries than usual.

Concept:
disk_purge is level 2 log rotation tool which works based on directory or file size. Level 2 means that this tool is optional. It could be installed and work with other log rotations. Using disk_purge, we can maintain directory size as we expect.

disk_purge [option]
       -c/--coinfig         config file
       -t/--target          Without config file, target and limit size can be specified using -t option
                            target and limit are separated by colon(:). i.e.) path:limit
       -d/--dryrun          Dryrun cleanup script. Show what files will be deleted.
       -f/--force           For directory less than 100mb
       -v/--verbose         Show what files are deleted

1. Set group name updating the yaml key  as follows.
$  hostgroup=<group name>

2. Create config file
config file format: yaml format

<group name>
  <directory or file path>:<limit>

# example of config file
ats:
  /var/logs/squid/archive: 100g
  /var/logs/mesos-slaves: 200g
  /var/log/spool/mail/root: 100m
common:
  /var/log/spool/mail/root: 100m

common group can be used for all the hosts disk_purge is installed.

features:
0. Files are deleted in order of age(mtime)
1. Subdirectories in the target directory are excluded to total directory size.
2. Also any files in the subdirectory is not deleted when cleaning up target directory
3. As default, files less than 2 days old are not deleted even if target directory reaches or exceeds to limit
   If you want to change default minimum age, set minimum_age as follows
