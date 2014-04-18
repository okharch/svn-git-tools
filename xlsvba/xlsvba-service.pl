use strict;
use warnings;
use Mojolicious::Lite;
use Mojo::Upload;
use File::Temp qw/ tempdir /;
use FindBin qw($Bin);
use Cwd qw(cwd);
use File::Slurp qw(read_file);

# we run this script to extract vba modules from xlsm file. please use full name of xls file as a parameter
# c:/cygwin/home/kharcheo/xlsvba/xlsvba.vbs file.xls
# it then produces folder with vba modules
my $xlsvba_vbs = "$Bin/xlsvba.vbs";
# make it full and windows compatible
$xlsvba_vbs = `cygpath -m $xlsvba_vbs`; 
chomp $xlsvba_vbs;
die "Can't find xlsvba.vbs script: $xlsvba_vbs" unless -f $xlsvba_vbs;

# show help for webservice usage
get '/' => {text => 'use /xlsvba path to upload xls file and receive tar.gz with vba modules, see xlsvba-client.pl for demo'};

# this request receives xls file using http upload mechanism. 
# it then extracts vba modules from it to folder, pack it to tar.gz 
# and returns produced archive to requester
post '/xlsvba' => sub {
    my $self  = shift;
    my $logger = $self->app->log;
    
    # receiveing file using http form upload technique
    my $filetype = $self->req->param('file');
    my $fileuploaded = $self->req->upload('file');
    $logger->debug("filetype: $filetype");
    $logger->debug("upload: $fileuploaded");
    
    return $self->render(text => 'File is not available.')
    unless ($fileuploaded);

    return $self->render(text => 'File is too big.', status => 200)
    if $self->req->is_limit_exceeded;
    
    # extract vba from xls
    my $filename = $fileuploaded->filename;
    my ($base) = $filename =~ m{(.*)\.};
    $logger->debug("filename:$filename, base: $base");    
    my $old_dir = cwd();
    my $tempdir = tempdir( CLEANUP => 1 );
    chdir($tempdir);
    my $xlsm = "$tempdir/$filename";
    $fileuploaded->move_to($xlsm);
    my $xlsm_w = `cygpath $xlsm -m`;
    chomp $xlsm_w;
    my $cmd = "cmd /c $xlsvba_vbs $xlsm_w";
    $logger->debug("xls2vba: $cmd");    
    system($cmd);
    
    # archive extracted modules
    my $tar = "$tempdir/$base.tar.gz";
    $cmd = "tar czf $tar $base/*";
    $logger->debug("tar : $cmd");    
    system($cmd);
    chdir($old_dir);

    # return archive to the requester
    my $data = read_file $tar, binmode => ':raw';
    #system("cp $tar /tmp"); # this is for debug
    return $self->render(data => $data); 
};

app->start;
