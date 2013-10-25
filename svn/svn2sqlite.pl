#!/home/kharcheo/bin/perl -w
use strict;
use warnings;
use Carp::Always;
use Date::Parse; 
use DBIx::Brev;
use XML::Simple qw(XMLin);
use Data::Dumper;
use Getopt::Long;

my $break = 0;
$SIG{INT} = $SIG{QUIT} = sub {$break = 1;printf "exiting by signal..."};

my (%path_branch,%path,%path_dir,%u_path_dir,%u_path_deleted,%path_deleted);
my ($last_author,$last_filename,$last_path,$pathrev,$branch);

sub flush_path_bfield($\%\%) {
    my ($field,$u_values,$values) = @_;
    my @keys = sort {$a <=> $b} grep {($u_values->{$_}||0) == (exists $values->{$_}?1:0)} keys %$u_values;
    return unless @keys;
    # boolean field expected, so group by values set and make update statements for each value
    my %values;
    push @{$values{$u_values->{$_}||'NULL'}},$_ for @keys;
    for my $value (keys %values) {
        my $ids = join ",", @{$values{$value}};
        my $sql = "update path set $field=$value where path in ($ids)";
        #print $sql;
        sql_exec $sql;
    }
}

$\="\n";

my $step = 100;
my $repo_root = '';
my $db = 'svn';
GetOptions("step=i" => \$step,'repo_root=s' => \$repo_root, 'db=s' => \$db);

print "Database (--db): $db";
print "Checking tables...";
db_use($db);
sql_exec "begin transaction";
create_db();

$repo_root = sql_value("select repo_root from vars");
print "Repository root (--repo_root): $repo_root\n";
die "repo root is invalid" unless $repo_root;

print "check write_lock...";
my $write_lock = sql_value("select write_lock from vars");
die "Can't proceed due write lock: $write_lock!\nTo resolve this make sure specified script is not working\nand if not please update vars set write_lock=null" if $write_lock;

print "start lock write transaction and put info to write_lock variable...";
sql_exec "commit transaction";

sql_exec "begin immediate transaction"; # commit is executed before program finishes to work, put write lock for all other clients
put_write_lock();

init_references();
import_last_revisions();
flush_path_bfield('deleted',%u_path_deleted,%path_deleted);
flush_path_bfield('dir',%u_path_dir,%path_dir);

# clear write lock & commit
clear_write_lock();
sql_exec "commit transaction";
exit 0;

sub create_db {
#create index if not exists path_fullname on path(folder_path,filename);
	sql_exec q{
create table if not exists path(path int not null primary key,branch integer,name text,filetype char(3),flags int,dir boolean, deleted boolean,index_content boolean,index_diff boolean);
create index if not exists path_filetype on path(filetype);
create table if not exists pathrev(pathrev int not null primary key,path int not null,rev int not null,kind varchar(4) not null,action char(1),indexed boolean);
create table if not exists rev(rev int not null primary key,author text,committed datetime not null,comment text);
create table if not exists branch(branch int not null primary key,path int not null,rev int not null,copy_from_path int not null,copy_from_rev int not null); 
create table if not exists vars(repo_root text,write_lock text);
	};
    unless (sql_value("select count(*) from vars")) {
        die "please specify --repo_root \$url" unless $repo_root;
        sql_exec "insert into vars(repo_root) values(?)",$repo_root;
    }
}

sub init_references {
    for (sql_query "select path,name,branch,dir,deleted from path") {
        my ($path,$name,$branch,$dir,$deleted) = @$_;
        $path{$name} = $path;
        $path_dir{$path} = undef if $dir;
        $path_deleted{$path} = undef if $deleted;
        $path_branch{$path} = $branch if $branch && $dir;
    }
    ($last_path,$pathrev,$branch) = map sql_value("select max($_) from $_"),
    qw(path pathrev branch);
}

my (@new_rev,@new_path,@new_branch,@pathrev);

my %typemap = qw(pm pl pl pl);
print get_filetype(@ARGV)."\n";
sub get_filetype {
    local $_ = shift;
    s{.*/}{};
    my ($type) = m{\.([^.]+)$};
    return undef unless $type;
    $type = lc($type);
    return exists $typemap{$type}?$typemap{$type}:$type;
}


sub name2path {
    my ($name) = @_;
    return $_ for grep $_,$path{$name};
    push @new_path,[++$last_path,$name,get_filetype($name)];
    $path{$name} = $last_path;
    return $last_path;
}

sub import_last_revisions {
    my $minrev = (sql_value("select max(rev) from rev") || 0) + 1;
    my $maxrev = svn_query("-l1")->{logentry}{revision};
    #$maxrev = 10 if $maxrev>10;
    print "repo_root:$repo_root\ndb:$db\nminrev:$minrev\nmaxrev:$maxrev\n";
    my $currev = $minrev;
    while (!$break && $currev <= $maxrev) {
        my $nextrev = $currev + $step - 1;
        $nextrev = $maxrev if $nextrev > $maxrev;
        eval {
            my $log = svn_query("-v -r $currev:$nextrev",1);
            process_svn_log($log) unless $break;
        };
        $currev = $nextrev + 1;
    }
    printf "done\n";
}

sub put_write_lock {
    $write_lock = sprintf("%s at %s by %s at %s",$0,map `$_`,qw(hostname whoami date));
    sql_exec "update vars set write_lock=?",$write_lock;
}

sub clear_write_lock {
    sql_exec "update vars set write_lock=null";
}

END { clear_write_lock };

sub svn_query {
	my ($cmd,$show_cmd) = @_;
	$cmd = "svn log --xml $cmd $repo_root";
	print "$cmd...\n" if $show_cmd;
	open(my $fh, '-|',$cmd);
	return XMLin($fh);
}

sub flush_new($\@) {
    my ($table_columns,$records) = @_;
    return unless @$records;
    inserts "insert into $table_columns",$records,step=>500;
    @$records = ();
}

sub process_svn_log {
	my ($log) = @_;
	$log = $log->{'logentry'};
	return unless $log;
	$log = [$log] unless ref($log) eq 'ARRAY';
	#print Dumper($svn_log);	exit;
	my $n = @$log;
	my $c = 0;
	for (@$log) {
		$c++;
		my ($msg,$rev,$date,$author) = @{$_}{qw(msg revision date author)};
		my $paths = $_->{paths}{path};
		$paths = [$paths] unless ref($paths) eq 'ARRAY';
		#printf "insert or ignore into commits(rev,author,committed,comment) values (%s,%s,%s,%s)\n", $rev,$author,$date,$msg;
		$msg = '' if ref($msg) eq 'HASH' && keys(%$msg) == 0;
		$msg =~ s/\s+/ /sg;
        push @new_rev,[$rev,$author,$date,$msg];
        push @pathrev, map add_pathrev($rev,$_), grep $_, @$paths;
	}
    flush_new("rev(rev,author,committed,comment)",@new_rev);
    $_->[3] = find_branch($_->[1]) for (@new_path);
    flush_new("path(path,name,filetype,branch)",@new_path);
    flush_new("branch(branch,path,rev,copy_from_path,copy_from_rev)",@new_branch);
    flush_new("pathrev(pathrev,rev,kind,action,path)",@pathrev);
}

sub update_path_deleted {
    my ($path,$action) = @_;
    my $path_deleted = exists $path_deleted{$path};
    if ($path_deleted) {
        if ($action ne "D") {
            delete $path_deleted{$path};
            $u_path_deleted{$path} = undef;
        }
    } else {
        if ($action eq "D") {
            $path_deleted{$path} = undef;
            $u_path_deleted{$path} = 1;            
        }        
    }
}

sub update_path_dir {
    my ($path,$kind) = @_;
    my $dir = exists $path_dir{$path};
    if ($dir) {
        if ($kind ne 'dir') {
            delete $path_dir{$path};
            $u_path_dir{$path} = undef;
        }
    }
    else {
        if ($kind eq 'dir') {
            $path_dir{$path} = undef;
            $u_path_dir{$path} = 1;
        }
    }    
}

sub add_pathrev {
    my ($rev,$entry) = @_;
    my ($kind,$action,$path,$path_from,$rev_from) = @{$entry}{qw(kind action content copyfrom-path copyfrom-rev)};
    $path = name2path($path);
    update_path_deleted $path, $action;
    update_path_dir $path, $kind;
    if ($path_from && $action eq 'A' && $kind eq 'dir') {
        $path_from = name2path($path_from);
        push @new_branch,[++$branch,$path,$rev,$path_from,$rev_from];
        $path_branch{$path_from} = $branch;
    }    
    return [++$pathrev,$rev,$kind,$action,$path];
}

sub find_branch {
    my ($name) = @_;
    return unless $name;
    if (exists $path{$name}) {
        my $path = $path{$name};
        return $path_branch{$path} if $path && exists $path_branch{$path};
    }
    my ($parent) = $name =~ m{^(.*)/};
    return find_branch($parent);
}
