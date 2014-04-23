use strict;
use warnings;
use HTTP::Request::Common;
use LWP::UserAgent;
use File::Temp qw(tempfile);

my ($file,$url) = @ARGV;

# this is for debug, comment it out for prod
$file ||= "/home/kharcheo/xlsvba/test.xlsm";
$url ||= "http://localhost:3000/xlsvba";

my ($path) = $file =~ m{^(.*)\.};

my $ua = LWP::UserAgent->new(
    env_proxy => 0,
    keep_alive => 1,
    timeout => 120,
    agent => 'Mozilla/5.0',
);

my $response = $ua->post(
    $url,
    Content_Type => 'form-data',
    Content      => [ "ac" => 'upload',  "file" => [ $file ] ]
);

#$req->authorization_basic('username', 'password');	

if ($response->is_success) {
    extract_modules($response->decoded_content,$path);
}
else {
    die $response->status_line;
}

sub extract_modules {
    my ($content,$path) = @_;
    # write response to temporary file
    my ($fh,$filename) = tempfile();    
    binmode($fh);# switch file mode to binary
    print $fh $content;
    close $fh;
    # rename it to have .tar.gz ending
    my $archive = "$filename.tar.gz";
    printf STDERR "temporary archive is $archive should contain %d bytes\n",length($content);
    system("mv $filename $archive");
    # remove folder with modules if any ...
    system("rm -rf $path");
    # exctract files from archive to $path
    system("tar xzf $archive");
    unlink($archive); # rm $archive
}
