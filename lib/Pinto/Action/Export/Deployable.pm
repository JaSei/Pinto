# ABSTRACT: generate deployable perl program as Export action

package Pinto::Action::Export::SystemTar;

use Moose;
use MooseX::StrictConstructor;
use MooseX::Types::Moose qw(Str);
use MooseX::MarkAsMethods (autoclean => 1);

use Try::Tiny;
use Path::Class;
use Data::Dumper;
use Capture::Tiny qw< capture >;
use File::Which qw< which >;
use File::Temp qw< tempfile >;

use Pinto::Util qw(mksymlink);
use Pinto::Action::Export::Tar;

#------------------------------------------------------------------------------

# VERSION

#------------------------------------------------------------------------------

with 'Pinto::Action::Export::ExporterRole';

has base => (
   is      => 'ro',
   default => sub {
      my ($fh, $filename) = tempfile();
      close $fh;
      return $filename;
   },
);

has archive => (
   is      => 'ro',
   lazy    => 1,
   default => sub {
      my $self = shift;
      my $base = file($self->base());
      return Pinto::Action::Export::Tar->new(
         path     => $base,
         exporter => $self->exporter(),
      );
   },
);

has remote => (
   is => 'ro',
   lazy => 1,
   default => sub {
      local $/;
      binmode DATA;
      return <DATA>;
   },
);

#------------------------------------------------------------------------------

sub insert {    # proxy to archive
   my ($self, $source, $destination) = @_;
   return $self->archive()->insert($source, $destination);
}

#------------------------------------------------------------------------------

sub link {      # proxy to archive
   my ($self, $from, $to) = @_;
   return $self->archive()->link($from, $to);
}

#------------------------------------------------------------------------------

sub close {
   my ($self) = @_;

   my $archive = $self->archive();
   $archive->insert(file(__FILE__)->parent()->file('premote'), 'premote');

   $self->archive()->close();

   my $target = $self->path();
   my $base   = $self->base();

   open my $out_fh, '>:raw', $target
      or die "open('$target'): $!";
   
   print {$out_fh} $self->remote();



   return;
} ## end sub close

sub header {
   my %params   = @_;
   my $namesize = length $params{name};
   return "$namesize $params{size}\n$params{name}";
}

sub print_section {
   my ($fh, $name, $data) = @_;
   
}

sub print_configuration {
   my ($fh, $config) = @_;
   my %general_configuration;
   for my $name (qw( workdir cleanup bundle deploy gzip bzip2 passthrough )) {
      $general_configuration{$name} = $config->{$name}
        if exists $config->{$name};
   }
   my $configuration = Dumper \%general_configuration;
   print {$fh} header(name => 'config.pl', size => length($configuration)),
      "\n", $configuration, "\n\n";
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;

#------------------------------------------------------------------------------

1;

__END__
#!/usr/bin/env perl
# *** NOTE *** LEAVE THIS MODULE LIST AS A PARAGRAPH
use strict;
use warnings;
use 5.006_002;
our $VERSION = '0.2.0';
use English qw( -no_match_vars );
use Fatal qw( close chdir opendir closedir );
use File::Temp qw( tempdir );
use File::Path qw( mkpath );
use File::Spec::Functions qw( file_name_is_absolute catfile );
use File::Basename qw( basename dirname );
use POSIX qw( strftime );
use Getopt::Long qw( :config gnu_getopt );
use Cwd qw( getcwd );
use Fcntl qw( :seek );

# __MOBUNDLE_INCLUSION__
BEGIN {
   my %file_for = (

      'Archive/Tar/File.pm' => <<'END_OF_FILE',
 package Archive::Tar::File;
 use strict;
 
 use Carp                ();
 use IO::File;
 use File::Spec::Unix    ();
 use File::Spec          ();
 use File::Basename      ();
 
 ### avoid circular use, so only require;
 require Archive::Tar;
 use Archive::Tar::Constant;
 
 use vars qw[@ISA $VERSION];
 #@ISA        = qw[Archive::Tar];
 $VERSION    = '1.92';
 
 ### set value to 1 to oct() it during the unpack ###
 
 my $tmpl = [
         name        => 0,   # string					A100
         mode        => 1,   # octal					A8
         uid         => 1,   # octal					A8
         gid         => 1,   # octal					A8
         size        => 0,   # octal	# cdrake - not *always* octal..	A12
         mtime       => 1,   # octal					A12
         chksum      => 1,   # octal					A8
         type        => 0,   # character					A1
         linkname    => 0,   # string					A100
         magic       => 0,   # string					A6
         version     => 0,   # 2 bytes					A2
         uname       => 0,   # string					A32
         gname       => 0,   # string					A32
         devmajor    => 1,   # octal					A8
         devminor    => 1,   # octal					A8
         prefix      => 0,	#					A155 x 12
 
 ### end UNPACK items ###
         raw         => 0,   # the raw data chunk
         data        => 0,   # the data associated with the file --
                             # This  might be very memory intensive
 ];
 
 ### install get/set accessors for this object.
 for ( my $i=0; $i<scalar @$tmpl ; $i+=2 ) {
     my $key = $tmpl->[$i];
     no strict 'refs';
     *{__PACKAGE__."::$key"} = sub {
         my $self = shift;
         $self->{$key} = $_[0] if @_;
 
         ### just in case the key is not there or undef or something ###
         {   local $^W = 0;
             return $self->{$key};
         }
     }
 }
 
 =head1 NAME
 
 Archive::Tar::File - a subclass for in-memory extracted file from Archive::Tar
 
 =head1 SYNOPSIS
 
     my @items = $tar->get_files;
 
     print $_->name, ' ', $_->size, "\n" for @items;
 
     print $object->get_content;
     $object->replace_content('new content');
 
     $object->rename( 'new/full/path/to/file.c' );
 
 =head1 DESCRIPTION
 
 Archive::Tar::Files provides a neat little object layer for in-memory
 extracted files. It's mostly used internally in Archive::Tar to tidy
 up the code, but there's no reason users shouldn't use this API as
 well.
 
 =head2 Accessors
 
 A lot of the methods in this package are accessors to the various
 fields in the tar header:
 
 =over 4
 
 =item name
 
 The file's name
 
 =item mode
 
 The file's mode
 
 =item uid
 
 The user id owning the file
 
 =item gid
 
 The group id owning the file
 
 =item size
 
 File size in bytes
 
 =item mtime
 
 Modification time. Adjusted to mac-time on MacOS if required
 
 =item chksum
 
 Checksum field for the tar header
 
 =item type
 
 File type -- numeric, but comparable to exported constants -- see
 Archive::Tar's documentation
 
 =item linkname
 
 If the file is a symlink, the file it's pointing to
 
 =item magic
 
 Tar magic string -- not useful for most users
 
 =item version
 
 Tar version string -- not useful for most users
 
 =item uname
 
 The user name that owns the file
 
 =item gname
 
 The group name that owns the file
 
 =item devmajor
 
 Device major number in case of a special file
 
 =item devminor
 
 Device minor number in case of a special file
 
 =item prefix
 
 Any directory to prefix to the extraction path, if any
 
 =item raw
 
 Raw tar header -- not useful for most users
 
 =back
 
 =head1 Methods
 
 =head2 Archive::Tar::File->new( file => $path )
 
 Returns a new Archive::Tar::File object from an existing file.
 
 Returns undef on failure.
 
 =head2 Archive::Tar::File->new( data => $path, $data, $opt )
 
 Returns a new Archive::Tar::File object from data.
 
 C<$path> defines the file name (which need not exist), C<$data> the
 file contents, and C<$opt> is a reference to a hash of attributes
 which may be used to override the default attributes (fields in the
 tar header), which are described above in the Accessors section.
 
 Returns undef on failure.
 
 =head2 Archive::Tar::File->new( chunk => $chunk )
 
 Returns a new Archive::Tar::File object from a raw 512-byte tar
 archive chunk.
 
 Returns undef on failure.
 
 =cut
 
 sub new {
     my $class   = shift;
     my $what    = shift;
 
     my $obj =   ($what eq 'chunk') ? __PACKAGE__->_new_from_chunk( @_ ) :
                 ($what eq 'file' ) ? __PACKAGE__->_new_from_file( @_ ) :
                 ($what eq 'data' ) ? __PACKAGE__->_new_from_data( @_ ) :
                 undef;
 
     return $obj;
 }
 
 ### copies the data, creates a clone ###
 sub clone {
     my $self = shift;
     return bless { %$self }, ref $self;
 }
 
 sub _new_from_chunk {
     my $class = shift;
     my $chunk = shift or return;    # 512 bytes of tar header
     my %hash  = @_;
 
     ### filter any arguments on defined-ness of values.
     ### this allows overriding from what the tar-header is saying
     ### about this tar-entry. Particularly useful for @LongLink files
     my %args  = map { $_ => $hash{$_} } grep { defined $hash{$_} } keys %hash;
 
     ### makes it start at 0 actually... :) ###
     my $i = -1;
     my %entry = map {
 	my ($s,$v)=($tmpl->[++$i],$tmpl->[++$i]);	# cdrake
 	($_)=($_=~/^([^\0]*)/) unless($s eq 'size');	# cdrake
 	$s=> $v ? oct $_ : $_				# cdrake
 	# $tmpl->[++$i] => $tmpl->[++$i] ? oct $_ : $_	# removed by cdrake - mucks up binary sizes >8gb
     } unpack( UNPACK, $chunk );				# cdrake
     # } map { /^([^\0]*)/ } unpack( UNPACK, $chunk );	# old - replaced now by cdrake
 
 
     if(substr($entry{'size'}, 0, 1) eq "\x80") {	# binary size extension for files >8gigs (> octal 77777777777777)	# cdrake
       my @sz=unpack("aCSNN",$entry{'size'}); $entry{'size'}=$sz[4]+(2**32)*$sz[3]+$sz[2]*(2**64);	# Use the low 80 bits (should use the upper 15 as well, but as at year 2011, that seems unlikely to ever be needed - the numbers are just too big...) # cdrake
     } else {	# cdrake
       ($entry{'size'})=($entry{'size'}=~/^([^\0]*)/); $entry{'size'}=oct $entry{'size'};	# cdrake
     }	# cdrake
 
 
     my $obj = bless { %entry, %args }, $class;
 
 	### magic is a filetype string.. it should have something like 'ustar' or
 	### something similar... if the chunk is garbage, skip it
 	return unless $obj->magic !~ /\W/;
 
     ### store the original chunk ###
     $obj->raw( $chunk );
 
     $obj->type(FILE) if ( (!length $obj->type) or ($obj->type =~ /\W/) );
     $obj->type(DIR)  if ( ($obj->is_file) && ($obj->name =~ m|/$|) );
 
 
     return $obj;
 
 }
 
 sub _new_from_file {
     my $class       = shift;
     my $path        = shift;
 
     ### path has to at least exist
     return unless defined $path;
 
     my $type        = __PACKAGE__->_filetype($path);
     my $data        = '';
 
     READ: {
         unless ($type == DIR ) {
             my $fh = IO::File->new;
 
             unless( $fh->open($path) ) {
                 ### dangling symlinks are fine, stop reading but continue
                 ### creating the object
                 last READ if $type == SYMLINK;
 
                 ### otherwise, return from this function --
                 ### anything that's *not* a symlink should be
                 ### resolvable
                 return;
             }
 
             ### binmode needed to read files properly on win32 ###
             binmode $fh;
             $data = do { local $/; <$fh> };
             close $fh;
         }
     }
 
     my @items       = qw[mode uid gid size mtime];
     my %hash        = map { shift(@items), $_ } (lstat $path)[2,4,5,7,9];
 
     if (ON_VMS) {
         ### VMS has two UID modes, traditional and POSIX.  Normally POSIX is
         ### not used.  We currently do not have an easy way to see if we are in
         ### POSIX mode.  In traditional mode, the UID is actually the VMS UIC.
         ### The VMS UIC has the upper 16 bits is the GID, which in many cases
         ### the VMS UIC will be larger than 209715, the largest that TAR can
         ### handle.  So for now, assume it is traditional if the UID is larger
         ### than 0x10000.
 
         if ($hash{uid} > 0x10000) {
             $hash{uid} = $hash{uid} & 0xFFFF;
         }
 
         ### The file length from stat() is the physical length of the file
         ### However the amount of data read in may be more for some file types.
         ### Fixed length files are read past the logical EOF to end of the block
         ### containing.  Other file types get expanded on read because record
         ### delimiters are added.
 
         my $data_len = length $data;
         $hash{size} = $data_len if $hash{size} < $data_len;
 
     }
     ### you *must* set size == 0 on symlinks, or the next entry will be
     ### though of as the contents of the symlink, which is wrong.
     ### this fixes bug #7937
     $hash{size}     = 0 if ($type == DIR or $type == SYMLINK);
     $hash{mtime}    -= TIME_OFFSET;
 
     ### strip the high bits off the mode, which we don't need to store
     $hash{mode}     = STRIP_MODE->( $hash{mode} );
 
 
     ### probably requires some file path munging here ... ###
     ### name and prefix are set later
     my $obj = {
         %hash,
         name        => '',
         chksum      => CHECK_SUM,
         type        => $type,
         linkname    => ($type == SYMLINK and CAN_READLINK)
                             ? readlink $path
                             : '',
         magic       => MAGIC,
         version     => TAR_VERSION,
         uname       => UNAME->( $hash{uid} ),
         gname       => GNAME->( $hash{gid} ),
         devmajor    => 0,   # not handled
         devminor    => 0,   # not handled
         prefix      => '',
         data        => $data,
     };
 
     bless $obj, $class;
 
     ### fix up the prefix and file from the path
     my($prefix,$file) = $obj->_prefix_and_file( $path );
     $obj->prefix( $prefix );
     $obj->name( $file );
 
     return $obj;
 }
 
 sub _new_from_data {
     my $class   = shift;
     my $path    = shift;    return unless defined $path;
     my $data    = shift;    return unless defined $data;
     my $opt     = shift;
 
     my $obj = {
         data        => $data,
         name        => '',
         mode        => MODE,
         uid         => UID,
         gid         => GID,
         size        => length $data,
         mtime       => time - TIME_OFFSET,
         chksum      => CHECK_SUM,
         type        => FILE,
         linkname    => '',
         magic       => MAGIC,
         version     => TAR_VERSION,
         uname       => UNAME->( UID ),
         gname       => GNAME->( GID ),
         devminor    => 0,
         devmajor    => 0,
         prefix      => '',
     };
 
     ### overwrite with user options, if provided ###
     if( $opt and ref $opt eq 'HASH' ) {
         for my $key ( keys %$opt ) {
 
             ### don't write bogus options ###
             next unless exists $obj->{$key};
             $obj->{$key} = $opt->{$key};
         }
     }
 
     bless $obj, $class;
 
     ### fix up the prefix and file from the path
     my($prefix,$file) = $obj->_prefix_and_file( $path );
     $obj->prefix( $prefix );
     $obj->name( $file );
 
     return $obj;
 }
 
 sub _prefix_and_file {
     my $self = shift;
     my $path = shift;
 
     my ($vol, $dirs, $file) = File::Spec->splitpath( $path, $self->is_dir );
     my @dirs = File::Spec->splitdir( $dirs );
 
     ### so sometimes the last element is '' -- probably when trailing
     ### dir slashes are encountered... this is of course pointless,
     ### so remove it
     pop @dirs while @dirs and not length $dirs[-1];
 
     ### if it's a directory, then $file might be empty
     $file = pop @dirs if $self->is_dir and not length $file;
 
     ### splitting ../ gives you the relative path in native syntax
     map { $_ = '..' if $_  eq '-' } @dirs if ON_VMS;
 
     my $prefix = File::Spec::Unix->catdir(
                         grep { length } $vol, @dirs
                     );
     return( $prefix, $file );
 }
 
 sub _filetype {
     my $self = shift;
     my $file = shift;
 
     return unless defined $file;
 
     return SYMLINK  if (-l $file);	# Symlink
 
     return FILE     if (-f _);		# Plain file
 
     return DIR      if (-d _);		# Directory
 
     return FIFO     if (-p _);		# Named pipe
 
     return SOCKET   if (-S _);		# Socket
 
     return BLOCKDEV if (-b _);		# Block special
 
     return CHARDEV  if (-c _);		# Character special
 
     ### shouldn't happen, this is when making archives, not reading ###
     return LONGLINK if ( $file eq LONGLINK_NAME );
 
     return UNKNOWN;		            # Something else (like what?)
 
 }
 
 ### this method 'downgrades' a file to plain file -- this is used for
 ### symlinks when FOLLOW_SYMLINKS is true.
 sub _downgrade_to_plainfile {
     my $entry = shift;
     $entry->type( FILE );
     $entry->mode( MODE );
     $entry->linkname('');
 
     return 1;
 }
 
 =head2 $bool = $file->extract( [ $alternative_name ] )
 
 Extract this object, optionally to an alternative name.
 
 See C<< Archive::Tar->extract_file >> for details.
 
 Returns true on success and false on failure.
 
 =cut
 
 sub extract {
     my $self = shift;
 
     local $Carp::CarpLevel += 1;
 
     return Archive::Tar->_extract_file( $self, @_ );
 }
 
 =head2 $path = $file->full_path
 
 Returns the full path from the tar header; this is basically a
 concatenation of the C<prefix> and C<name> fields.
 
 =cut
 
 sub full_path {
     my $self = shift;
 
     ### if prefix field is empty
     return $self->name unless defined $self->prefix and length $self->prefix;
 
     ### or otherwise, catfile'd
     return File::Spec::Unix->catfile( $self->prefix, $self->name );
 }
 
 
 =head2 $bool = $file->validate
 
 Done by Archive::Tar internally when reading the tar file:
 validate the header against the checksum to ensure integer tar file.
 
 Returns true on success, false on failure
 
 =cut
 
 sub validate {
     my $self = shift;
 
     my $raw = $self->raw;
 
     ### don't know why this one is different from the one we /write/ ###
     substr ($raw, 148, 8) = "        ";
 
     ### bug #43513: [PATCH] Accept wrong checksums from SunOS and HP-UX tar
     ### like GNU tar does. See here for details:
     ### http://www.gnu.org/software/tar/manual/tar.html#SEC139
     ### so we do both a signed AND unsigned validate. if one succeeds, that's
     ### good enough
 	return (   (unpack ("%16C*", $raw) == $self->chksum)
 	        or (unpack ("%16c*", $raw) == $self->chksum)) ? 1 : 0;
 }
 
 =head2 $bool = $file->has_content
 
 Returns a boolean to indicate whether the current object has content.
 Some special files like directories and so on never will have any
 content. This method is mainly to make sure you don't get warnings
 for using uninitialized values when looking at an object's content.
 
 =cut
 
 sub has_content {
     my $self = shift;
     return defined $self->data() && length $self->data() ? 1 : 0;
 }
 
 =head2 $content = $file->get_content
 
 Returns the current content for the in-memory file
 
 =cut
 
 sub get_content {
     my $self = shift;
     $self->data( );
 }
 
 =head2 $cref = $file->get_content_by_ref
 
 Returns the current content for the in-memory file as a scalar
 reference. Normal users won't need this, but it will save memory if
 you are dealing with very large data files in your tar archive, since
 it will pass the contents by reference, rather than make a copy of it
 first.
 
 =cut
 
 sub get_content_by_ref {
     my $self = shift;
 
     return \$self->{data};
 }
 
 =head2 $bool = $file->replace_content( $content )
 
 Replace the current content of the file with the new content. This
 only affects the in-memory archive, not the on-disk version until
 you write it.
 
 Returns true on success, false on failure.
 
 =cut
 
 sub replace_content {
     my $self = shift;
     my $data = shift || '';
 
     $self->data( $data );
     $self->size( length $data );
     return 1;
 }
 
 =head2 $bool = $file->rename( $new_name )
 
 Rename the current file to $new_name.
 
 Note that you must specify a Unix path for $new_name, since per tar
 standard, all files in the archive must be Unix paths.
 
 Returns true on success and false on failure.
 
 =cut
 
 sub rename {
     my $self = shift;
     my $path = shift;
 
     return unless defined $path;
 
     my ($prefix,$file) = $self->_prefix_and_file( $path );
 
     $self->name( $file );
     $self->prefix( $prefix );
 
 	return 1;
 }
 
 =head2 $bool = $file->chmod $mode)
 
 Change mode of $file to $mode. The mode can be a string or a number
 which is interpreted as octal whether or not a leading 0 is given.
 
 Returns true on success and false on failure.
 
 =cut
 
 sub chmod {
     my $self  = shift;
     my $mode = shift; return unless defined $mode && $mode =~ /^[0-7]{1,4}$/;
     $self->{mode} = oct($mode);
     return 1;
 }
 
 =head2 $bool = $file->chown( $user [, $group])
 
 Change owner of $file to $user. If a $group is given that is changed
 as well. You can also pass a single parameter with a colon separating the
 use and group as in 'root:wheel'.
 
 Returns true on success and false on failure.
 
 =cut
 
 sub chown {
     my $self = shift;
     my $uname = shift;
     return unless defined $uname;
     my $gname;
     if (-1 != index($uname, ':')) {
 	($uname, $gname) = split(/:/, $uname);
     } else {
 	$gname = shift if @_ > 0;
     }
 
     $self->uname( $uname );
     $self->gname( $gname ) if $gname;
 	return 1;
 }
 
 =head1 Convenience methods
 
 To quickly check the type of a C<Archive::Tar::File> object, you can
 use the following methods:
 
 =over 4
 
 =item $file->is_file
 
 Returns true if the file is of type C<file>
 
 =item $file->is_dir
 
 Returns true if the file is of type C<dir>
 
 =item $file->is_hardlink
 
 Returns true if the file is of type C<hardlink>
 
 =item $file->is_symlink
 
 Returns true if the file is of type C<symlink>
 
 =item $file->is_chardev
 
 Returns true if the file is of type C<chardev>
 
 =item $file->is_blockdev
 
 Returns true if the file is of type C<blockdev>
 
 =item $file->is_fifo
 
 Returns true if the file is of type C<fifo>
 
 =item $file->is_socket
 
 Returns true if the file is of type C<socket>
 
 =item $file->is_longlink
 
 Returns true if the file is of type C<LongLink>.
 Should not happen after a successful C<read>.
 
 =item $file->is_label
 
 Returns true if the file is of type C<Label>.
 Should not happen after a successful C<read>.
 
 =item $file->is_unknown
 
 Returns true if the file type is C<unknown>
 
 =back
 
 =cut
 
 #stupid perl5.5.3 needs to warn if it's not numeric
 sub is_file     { local $^W;    FILE      == $_[0]->type }
 sub is_dir      { local $^W;    DIR       == $_[0]->type }
 sub is_hardlink { local $^W;    HARDLINK  == $_[0]->type }
 sub is_symlink  { local $^W;    SYMLINK   == $_[0]->type }
 sub is_chardev  { local $^W;    CHARDEV   == $_[0]->type }
 sub is_blockdev { local $^W;    BLOCKDEV  == $_[0]->type }
 sub is_fifo     { local $^W;    FIFO      == $_[0]->type }
 sub is_socket   { local $^W;    SOCKET    == $_[0]->type }
 sub is_unknown  { local $^W;    UNKNOWN   == $_[0]->type }
 sub is_longlink { local $^W;    LONGLINK  eq $_[0]->type }
 sub is_label    { local $^W;    LABEL     eq $_[0]->type }
 
 1;

END_OF_FILE

      'Archive/Tar.pm' => <<'END_OF_FILE',
 ### the gnu tar specification:
 ### http://www.gnu.org/software/tar/manual/tar.html
 ###
 ### and the pax format spec, which tar derives from:
 ### http://www.opengroup.org/onlinepubs/007904975/utilities/pax.html
 
 package Archive::Tar;
 require 5.005_03;
 
 use Cwd;
 use IO::Zlib;
 use IO::File;
 use Carp                qw(carp croak);
 use File::Spec          ();
 use File::Spec::Unix    ();
 use File::Path          ();
 
 use Archive::Tar::File;
 use Archive::Tar::Constant;
 
 require Exporter;
 
 use strict;
 use vars qw[$DEBUG $error $VERSION $WARN $FOLLOW_SYMLINK $CHOWN $CHMOD
             $DO_NOT_USE_PREFIX $HAS_PERLIO $HAS_IO_STRING $SAME_PERMISSIONS
             $INSECURE_EXTRACT_MODE $ZERO_PAD_NUMBERS @ISA @EXPORT
          ];
 
 @ISA                    = qw[Exporter];
 @EXPORT                 = qw[ COMPRESS_GZIP COMPRESS_BZIP ];
 $DEBUG                  = 0;
 $WARN                   = 1;
 $FOLLOW_SYMLINK         = 0;
 $VERSION                = "1.92";
 $CHOWN                  = 1;
 $CHMOD                  = 1;
 $SAME_PERMISSIONS       = $> == 0 ? 1 : 0;
 $DO_NOT_USE_PREFIX      = 0;
 $INSECURE_EXTRACT_MODE  = 0;
 $ZERO_PAD_NUMBERS       = 0;
 
 BEGIN {
     use Config;
     $HAS_PERLIO = $Config::Config{useperlio};
 
     ### try and load IO::String anyway, so you can dynamically
     ### switch between perlio and IO::String
     $HAS_IO_STRING = eval {
         require IO::String;
         import IO::String;
         1;
     } || 0;
 }
 
 =head1 NAME
 
 Archive::Tar - module for manipulations of tar archives
 
 =head1 SYNOPSIS
 
     use Archive::Tar;
     my $tar = Archive::Tar->new;
 
     $tar->read('origin.tgz');
     $tar->extract();
 
     $tar->add_files('file/foo.pl', 'docs/README');
     $tar->add_data('file/baz.txt', 'This is the contents now');
 
     $tar->rename('oldname', 'new/file/name');
     $tar->chown('/', 'root');
     $tar->chown('/', 'root:root');
     $tar->chmod('/tmp', '1777');
 
     $tar->write('files.tar');                   # plain tar
     $tar->write('files.tgz', COMPRESS_GZIP);    # gzip compressed
     $tar->write('files.tbz', COMPRESS_BZIP);    # bzip2 compressed
 
 =head1 DESCRIPTION
 
 Archive::Tar provides an object oriented mechanism for handling tar
 files.  It provides class methods for quick and easy files handling
 while also allowing for the creation of tar file objects for custom
 manipulation.  If you have the IO::Zlib module installed,
 Archive::Tar will also support compressed or gzipped tar files.
 
 An object of class Archive::Tar represents a .tar(.gz) archive full
 of files and things.
 
 =head1 Object Methods
 
 =head2 Archive::Tar->new( [$file, $compressed] )
 
 Returns a new Tar object. If given any arguments, C<new()> calls the
 C<read()> method automatically, passing on the arguments provided to
 the C<read()> method.
 
 If C<new()> is invoked with arguments and the C<read()> method fails
 for any reason, C<new()> returns undef.
 
 =cut
 
 my $tmpl = {
     _data   => [ ],
     _file   => 'Unknown',
 };
 
 ### install get/set accessors for this object.
 for my $key ( keys %$tmpl ) {
     no strict 'refs';
     *{__PACKAGE__."::$key"} = sub {
         my $self = shift;
         $self->{$key} = $_[0] if @_;
         return $self->{$key};
     }
 }
 
 sub new {
     my $class = shift;
     $class = ref $class if ref $class;
 
     ### copying $tmpl here since a shallow copy makes it use the
     ### same aref, causing for files to remain in memory always.
     my $obj = bless { _data => [ ], _file => 'Unknown', _error => '' }, $class;
 
     if (@_) {
         unless ( $obj->read( @_ ) ) {
             $obj->_error(qq[No data could be read from file]);
             return;
         }
     }
 
     return $obj;
 }
 
 =head2 $tar->read ( $filename|$handle, [$compressed, {opt => 'val'}] )
 
 Read the given tar file into memory.
 The first argument can either be the name of a file or a reference to
 an already open filehandle (or an IO::Zlib object if it's compressed)
 
 The C<read> will I<replace> any previous content in C<$tar>!
 
 The second argument may be considered optional, but remains for
 backwards compatibility. Archive::Tar now looks at the file
 magic to determine what class should be used to open the file
 and will transparently Do The Right Thing.
 
 Archive::Tar will warn if you try to pass a bzip2 compressed file and the
 IO::Zlib / IO::Uncompress::Bunzip2 modules are not available and simply return.
 
 Note that you can currently B<not> pass a C<gzip> compressed
 filehandle, which is not opened with C<IO::Zlib>, a C<bzip2> compressed
 filehandle, which is not opened with C<IO::Uncompress::Bunzip2>, nor a string
 containing the full archive information (either compressed or
 uncompressed). These are worth while features, but not currently
 implemented. See the C<TODO> section.
 
 The third argument can be a hash reference with options. Note that
 all options are case-sensitive.
 
 =over 4
 
 =item limit
 
 Do not read more than C<limit> files. This is useful if you have
 very big archives, and are only interested in the first few files.
 
 =item filter
 
 Can be set to a regular expression.  Only files with names that match
 the expression will be read.
 
 =item md5
 
 Set to 1 and the md5sum of files will be returned (instead of file data)
     my $iter = Archive::Tar->iter( $file,  1, {md5 => 1} );
     while( my $f = $iter->() ) {
         print $f->data . "\t" . $f->full_path . $/;
     }
 
 =item extract
 
 If set to true, immediately extract entries when reading them. This
 gives you the same memory break as the C<extract_archive> function.
 Note however that entries will not be read into memory, but written
 straight to disk. This means no C<Archive::Tar::File> objects are
 created for you to inspect.
 
 =back
 
 All files are stored internally as C<Archive::Tar::File> objects.
 Please consult the L<Archive::Tar::File> documentation for details.
 
 Returns the number of files read in scalar context, and a list of
 C<Archive::Tar::File> objects in list context.
 
 =cut
 
 sub read {
     my $self = shift;
     my $file = shift;
     my $gzip = shift || 0;
     my $opts = shift || {};
 
     unless( defined $file ) {
         $self->_error( qq[No file to read from!] );
         return;
     } else {
         $self->_file( $file );
     }
 
     my $handle = $self->_get_handle($file, $gzip, READ_ONLY->( ZLIB ) )
                     or return;
 
     my $data = $self->_read_tar( $handle, $opts ) or return;
 
     $self->_data( $data );
 
     return wantarray ? @$data : scalar @$data;
 }
 
 sub _get_handle {
     my $self     = shift;
     my $file     = shift;   return unless defined $file;
     my $compress = shift || 0;
     my $mode     = shift || READ_ONLY->( ZLIB ); # default to read only
 
     ### Check if file is a file handle or IO glob
     if ( ref $file ) {
 	return $file if eval{ *$file{IO} };
 	return $file if eval{ $file->isa(q{IO::Handle}) };
 	$file = q{}.$file;
     }
 
     ### get a FH opened to the right class, so we can use it transparently
     ### throughout the program
     my $fh;
     {   ### reading magic only makes sense if we're opening a file for
         ### reading. otherwise, just use what the user requested.
         my $magic = '';
         if( MODE_READ->($mode) ) {
             open my $tmp, $file or do {
                 $self->_error( qq[Could not open '$file' for reading: $!] );
                 return;
             };
 
             ### read the first 4 bites of the file to figure out which class to
             ### use to open the file.
             sysread( $tmp, $magic, 4 );
             close $tmp;
         }
 
         ### is it bzip?
         ### if you asked specifically for bzip compression, or if we're in
         ### read mode and the magic numbers add up, use bzip
         if( BZIP and (
                 ($compress eq COMPRESS_BZIP) or
                 ( MODE_READ->($mode) and $magic =~ BZIP_MAGIC_NUM )
             )
         ) {
 
             ### different reader/writer modules, different error vars... sigh
             if( MODE_READ->($mode) ) {
                 $fh = IO::Uncompress::Bunzip2->new( $file ) or do {
                     $self->_error( qq[Could not read '$file': ] .
                         $IO::Uncompress::Bunzip2::Bunzip2Error
                     );
                     return;
                 };
 
             } else {
                 $fh = IO::Compress::Bzip2->new( $file ) or do {
                     $self->_error( qq[Could not write to '$file': ] .
                         $IO::Compress::Bzip2::Bzip2Error
                     );
                     return;
                 };
             }
 
         ### is it gzip?
         ### if you asked for compression, if you wanted to read or the gzip
         ### magic number is present (redundant with read)
         } elsif( ZLIB and (
                     $compress or MODE_READ->($mode) or $magic =~ GZIP_MAGIC_NUM
                  )
         ) {
             $fh = IO::Zlib->new;
 
             unless( $fh->open( $file, $mode ) ) {
                 $self->_error(qq[Could not create filehandle for '$file': $!]);
                 return;
             }
 
         ### is it plain tar?
         } else {
             $fh = IO::File->new;
 
             unless( $fh->open( $file, $mode ) ) {
                 $self->_error(qq[Could not create filehandle for '$file': $!]);
                 return;
             }
 
             ### enable bin mode on tar archives
             binmode $fh;
         }
     }
 
     return $fh;
 }
 
 
 sub _read_tar {
     my $self    = shift;
     my $handle  = shift or return;
     my $opts    = shift || {};
 
     my $count   = $opts->{limit}    || 0;
     my $filter  = $opts->{filter};
     my $md5  = $opts->{md5} || 0;	# cdrake
     my $filter_cb = $opts->{filter_cb};
     my $extract = $opts->{extract}  || 0;
 
     ### set a cap on the amount of files to extract ###
     my $limit   = 0;
     $limit = 1 if $count > 0;
 
     my $tarfile = [ ];
     my $chunk;
     my $read = 0;
     my $real_name;  # to set the name of a file when
                     # we're encountering @longlink
     my $data;
 
     LOOP:
     while( $handle->read( $chunk, HEAD ) ) {
         ### IO::Zlib doesn't support this yet
         my $offset;
         if ( ref($handle) ne 'IO::Zlib' ) {
             local $@;
             $offset = eval { tell $handle } || 'unknown';
             $@ = '';
         }
         else {
             $offset = 'unknown';
         }
 
         unless( $read++ ) {
             my $gzip = GZIP_MAGIC_NUM;
             if( $chunk =~ /$gzip/ ) {
                 $self->_error( qq[Cannot read compressed format in tar-mode] );
                 return;
             }
 
             ### size is < HEAD, which means a corrupted file, as the minimum
             ### length is _at least_ HEAD
             if (length $chunk != HEAD) {
                 $self->_error( qq[Cannot read enough bytes from the tarfile] );
                 return;
             }
         }
 
         ### if we can't read in all bytes... ###
         last if length $chunk != HEAD;
 
         ### Apparently this should really be two blocks of 512 zeroes,
         ### but GNU tar sometimes gets it wrong. See comment in the
         ### source code (tar.c) to GNU cpio.
         next if $chunk eq TAR_END;
 
         ### according to the posix spec, the last 12 bytes of the header are
         ### null bytes, to pad it to a 512 byte block. That means if these
         ### bytes are NOT null bytes, it's a corrupt header. See:
         ### www.koders.com/c/fidCE473AD3D9F835D690259D60AD5654591D91D5BA.aspx
         ### line 111
         {   my $nulls = join '', "\0" x 12;
             unless( $nulls eq substr( $chunk, 500, 12 ) ) {
                 $self->_error( qq[Invalid header block at offset $offset] );
                 next LOOP;
             }
         }
 
         ### pass the realname, so we can set it 'proper' right away
         ### some of the heuristics are done on the name, so important
         ### to set it ASAP
         my $entry;
         {   my %extra_args = ();
             $extra_args{'name'} = $$real_name if defined $real_name;
 
             unless( $entry = Archive::Tar::File->new(   chunk => $chunk,
                                                         %extra_args )
             ) {
                 $self->_error( qq[Couldn't read chunk at offset $offset] );
                 next LOOP;
             }
         }
 
         ### ignore labels:
         ### http://www.gnu.org/software/tar/manual/html_chapter/Media.html#SEC159
         next if $entry->is_label;
 
         if( length $entry->type and ($entry->is_file || $entry->is_longlink) ) {
 
             if ( $entry->is_file && !$entry->validate ) {
                 ### sometimes the chunk is rather fux0r3d and a whole 512
                 ### bytes ends up in the ->name area.
                 ### clean it up, if need be
                 my $name = $entry->name;
                 $name = substr($name, 0, 100) if length $name > 100;
                 $name =~ s/\n/ /g;
 
                 $self->_error( $name . qq[: checksum error] );
                 next LOOP;
             }
 
             my $block = BLOCK_SIZE->( $entry->size );
 
             $data = $entry->get_content_by_ref;
 
 	    my $skip = 0;
 	    my $ctx;			# cdrake
 	    ### skip this entry if we're filtering
 
 	    if($md5) {			# cdrake
 	      $ctx = Digest::MD5->new;	# cdrake
 	        $skip=5;		# cdrake
 
 	    } elsif ($filter && $entry->name !~ $filter) {
 		$skip = 1;
 
 	    ### skip this entry if it's a pax header. This is a special file added
 	    ### by, among others, git-generated tarballs. It holds comments and is
 	    ### not meant for extracting. See #38932: pax_global_header extracted
 	    } elsif ( $entry->name eq PAX_HEADER or $entry->type =~ /^(x|g)$/ ) {
 		$skip = 2;
 	    } elsif ($filter_cb && ! $filter_cb->($entry)) {
 		$skip = 3;
 	    }
 
 	    if ($skip) {
 		#
 		# Since we're skipping, do not allocate memory for the
 		# whole file.  Read it 64 BLOCKS at a time.  Do not
 		# complete the skip yet because maybe what we read is a
 		# longlink and it won't get skipped after all
 		#
 		my $amt = $block;
 		my $fsz=$entry->size;	# cdrake
 		while ($amt > 0) {
 		    $$data = '';
 		    my $this = 64 * BLOCK;
 		    $this = $amt if $this > $amt;
 		    if( $handle->read( $$data, $this ) < $this ) {
 			$self->_error( qq[Read error on tarfile (missing data) '].
 					    $entry->full_path ."' at offset $offset" );
 			next LOOP;
 		    }
 		    $amt -= $this;
 		    $fsz -= $this;	# cdrake
 		substr ($$data, $fsz) = "" if ($fsz<0);	# remove external junk prior to md5	# cdrake
 		$ctx->add($$data) if($skip==5);	# cdrake
 		}
 		$$data = $ctx->hexdigest if($skip==5 && !$entry->is_longlink && !$entry->is_unknown && !$entry->is_label ) ;	# cdrake
             } else {
 
 		### just read everything into memory
 		### can't do lazy loading since IO::Zlib doesn't support 'seek'
 		### this is because Compress::Zlib doesn't support it =/
 		### this reads in the whole data in one read() call.
 		if ( $handle->read( $$data, $block ) < $block ) {
 		    $self->_error( qq[Read error on tarfile (missing data) '].
                                     $entry->full_path ."' at offset $offset" );
 		    next LOOP;
 		}
 		### throw away trailing garbage ###
 		substr ($$data, $entry->size) = "" if defined $$data;
             }
 
             ### part II of the @LongLink munging -- need to do /after/
             ### the checksum check.
             if( $entry->is_longlink ) {
                 ### weird thing in tarfiles -- if the file is actually a
                 ### @LongLink, the data part seems to have a trailing ^@
                 ### (unprintable) char. to display, pipe output through less.
                 ### but that doesn't *always* happen.. so check if the last
                 ### character is a control character, and if so remove it
                 ### at any rate, we better remove that character here, or tests
                 ### like 'eq' and hash lookups based on names will SO not work
                 ### remove it by calculating the proper size, and then
                 ### tossing out everything that's longer than that size.
 
                 ### count number of nulls
                 my $nulls = $$data =~ tr/\0/\0/;
 
                 ### cut data + size by that many bytes
                 $entry->size( $entry->size - $nulls );
                 substr ($$data, $entry->size) = "";
             }
         }
 
         ### clean up of the entries.. posix tar /apparently/ has some
         ### weird 'feature' that allows for filenames > 255 characters
         ### they'll put a header in with as name '././@LongLink' and the
         ### contents will be the name of the /next/ file in the archive
         ### pretty crappy and kludgy if you ask me
 
         ### set the name for the next entry if this is a @LongLink;
         ### this is one ugly hack =/ but needed for direct extraction
         if( $entry->is_longlink ) {
             $real_name = $data;
             next LOOP;
         } elsif ( defined $real_name ) {
             $entry->name( $$real_name );
             $entry->prefix('');
             undef $real_name;
         }
 
 	if ($filter && $entry->name !~ $filter) {
 	    next LOOP;
 
 	### skip this entry if it's a pax header. This is a special file added
 	### by, among others, git-generated tarballs. It holds comments and is
 	### not meant for extracting. See #38932: pax_global_header extracted
 	} elsif ( $entry->name eq PAX_HEADER or $entry->type =~ /^(x|g)$/ ) {
 	    next LOOP;
 	} elsif ($filter_cb && ! $filter_cb->($entry)) {
 	    next LOOP;
 	}
 
         if ( $extract && !$entry->is_longlink
                       && !$entry->is_unknown
                       && !$entry->is_label ) {
             $self->_extract_file( $entry ) or return;
         }
 
         ### Guard against tarfiles with garbage at the end
 	    last LOOP if $entry->name eq '';
 
         ### push only the name on the rv if we're extracting
         ### -- for extract_archive
         push @$tarfile, ($extract ? $entry->name : $entry);
 
         if( $limit ) {
             $count-- unless $entry->is_longlink || $entry->is_dir;
             last LOOP unless $count;
         }
     } continue {
         undef $data;
     }
 
     return $tarfile;
 }
 
 =head2 $tar->contains_file( $filename )
 
 Check if the archive contains a certain file.
 It will return true if the file is in the archive, false otherwise.
 
 Note however, that this function does an exact match using C<eq>
 on the full path. So it cannot compensate for case-insensitive file-
 systems or compare 2 paths to see if they would point to the same
 underlying file.
 
 =cut
 
 sub contains_file {
     my $self = shift;
     my $full = shift;
 
     return unless defined $full;
 
     ### don't warn if the entry isn't there.. that's what this function
     ### is for after all.
     local $WARN = 0;
     return 1 if $self->_find_entry($full);
     return;
 }
 
 =head2 $tar->extract( [@filenames] )
 
 Write files whose names are equivalent to any of the names in
 C<@filenames> to disk, creating subdirectories as necessary. This
 might not work too well under VMS.
 Under MacPerl, the file's modification time will be converted to the
 MacOS zero of time, and appropriate conversions will be done to the
 path.  However, the length of each element of the path is not
 inspected to see whether it's longer than MacOS currently allows (32
 characters).
 
 If C<extract> is called without a list of file names, the entire
 contents of the archive are extracted.
 
 Returns a list of filenames extracted.
 
 =cut
 
 sub extract {
     my $self    = shift;
     my @args    = @_;
     my @files;
 
     # use the speed optimization for all extracted files
     local($self->{cwd}) = cwd() unless $self->{cwd};
 
     ### you requested the extraction of only certain files
     if( @args ) {
         for my $file ( @args ) {
 
             ### it's already an object?
             if( UNIVERSAL::isa( $file, 'Archive::Tar::File' ) ) {
                 push @files, $file;
                 next;
 
             ### go find it then
             } else {
 
                 my $found;
                 for my $entry ( @{$self->_data} ) {
                     next unless $file eq $entry->full_path;
 
                     ### we found the file you're looking for
                     push @files, $entry;
                     $found++;
                 }
 
                 unless( $found ) {
                     return $self->_error(
                         qq[Could not find '$file' in archive] );
                 }
             }
         }
 
     ### just grab all the file items
     } else {
         @files = $self->get_files;
     }
 
     ### nothing found? that's an error
     unless( scalar @files ) {
         $self->_error( qq[No files found for ] . $self->_file );
         return;
     }
 
     ### now extract them
     for my $entry ( @files ) {
         unless( $self->_extract_file( $entry ) ) {
             $self->_error(q[Could not extract ']. $entry->full_path .q['] );
             return;
         }
     }
 
     return @files;
 }
 
 =head2 $tar->extract_file( $file, [$extract_path] )
 
 Write an entry, whose name is equivalent to the file name provided to
 disk. Optionally takes a second parameter, which is the full native
 path (including filename) the entry will be written to.
 
 For example:
 
     $tar->extract_file( 'name/in/archive', 'name/i/want/to/give/it' );
 
     $tar->extract_file( $at_file_object,   'name/i/want/to/give/it' );
 
 Returns true on success, false on failure.
 
 =cut
 
 sub extract_file {
     my $self = shift;
     my $file = shift;   return unless defined $file;
     my $alt  = shift;
 
     my $entry = $self->_find_entry( $file )
         or $self->_error( qq[Could not find an entry for '$file'] ), return;
 
     return $self->_extract_file( $entry, $alt );
 }
 
 sub _extract_file {
     my $self    = shift;
     my $entry   = shift or return;
     my $alt     = shift;
 
     ### you wanted an alternate extraction location ###
     my $name = defined $alt ? $alt : $entry->full_path;
 
                             ### splitpath takes a bool at the end to indicate
                             ### that it's splitting a dir
     my ($vol,$dirs,$file);
     if ( defined $alt ) { # It's a local-OS path
         ($vol,$dirs,$file) = File::Spec->splitpath(       $alt,
                                                           $entry->is_dir );
     } else {
         ($vol,$dirs,$file) = File::Spec::Unix->splitpath( $name,
                                                           $entry->is_dir );
     }
 
     my $dir;
     ### is $name an absolute path? ###
     if( $vol || File::Spec->file_name_is_absolute( $dirs ) ) {
 
         ### absolute names are not allowed to be in tarballs under
         ### strict mode, so only allow it if a user tells us to do it
         if( not defined $alt and not $INSECURE_EXTRACT_MODE ) {
             $self->_error(
                 q[Entry ']. $entry->full_path .q[' is an absolute path. ].
                 q[Not extracting absolute paths under SECURE EXTRACT MODE]
             );
             return;
         }
 
         ### user asked us to, it's fine.
         $dir = File::Spec->catpath( $vol, $dirs, "" );
 
     ### it's a relative path ###
     } else {
         my $cwd     = (ref $self and defined $self->{cwd})
                         ? $self->{cwd}
                         : cwd();
 
         my @dirs = defined $alt
             ? File::Spec->splitdir( $dirs )         # It's a local-OS path
             : File::Spec::Unix->splitdir( $dirs );  # it's UNIX-style, likely
                                                     # straight from the tarball
 
         if( not defined $alt            and
             not $INSECURE_EXTRACT_MODE
         ) {
 
             ### paths that leave the current directory are not allowed under
             ### strict mode, so only allow it if a user tells us to do this.
             if( grep { $_ eq '..' } @dirs ) {
 
                 $self->_error(
                     q[Entry ']. $entry->full_path .q[' is attempting to leave ].
                     q[the current working directory. Not extracting under ].
                     q[SECURE EXTRACT MODE]
                 );
                 return;
             }
 
             ### the archive may be asking us to extract into a symlink. This
             ### is not sane and a possible security issue, as outlined here:
             ### https://rt.cpan.org/Ticket/Display.html?id=30380
             ### https://bugzilla.redhat.com/show_bug.cgi?id=295021
             ### https://issues.rpath.com/browse/RPL-1716
             my $full_path = $cwd;
             for my $d ( @dirs ) {
                 $full_path = File::Spec->catdir( $full_path, $d );
 
                 ### we've already checked this one, and it's safe. Move on.
                 next if ref $self and $self->{_link_cache}->{$full_path};
 
                 if( -l $full_path ) {
                     my $to   = readlink $full_path;
                     my $diag = "symlinked directory ($full_path => $to)";
 
                     $self->_error(
                         q[Entry ']. $entry->full_path .q[' is attempting to ].
                         qq[extract to a $diag. This is considered a security ].
                         q[vulnerability and not allowed under SECURE EXTRACT ].
                         q[MODE]
                     );
                     return;
                 }
 
                 ### XXX keep a cache if possible, so the stats become cheaper:
                 $self->{_link_cache}->{$full_path} = 1 if ref $self;
             }
         }
 
         ### '.' is the directory delimiter on VMS, which has to be escaped
         ### or changed to '_' on vms.  vmsify is used, because older versions
         ### of vmspath do not handle this properly.
         ### Must not add a '/' to an empty directory though.
         map { length() ? VMS::Filespec::vmsify($_.'/') : $_ } @dirs if ON_VMS;
 
         my ($cwd_vol,$cwd_dir,$cwd_file)
                     = File::Spec->splitpath( $cwd );
         my @cwd     = File::Spec->splitdir( $cwd_dir );
         push @cwd, $cwd_file if length $cwd_file;
 
         ### We need to pass '' as the last element to catpath. Craig Berry
         ### explains why (msgid <p0624083dc311ae541393@[172.16.52.1]>):
         ### The root problem is that splitpath on UNIX always returns the
         ### final path element as a file even if it is a directory, and of
         ### course there is no way it can know the difference without checking
         ### against the filesystem, which it is documented as not doing.  When
         ### you turn around and call catpath, on VMS you have to know which bits
         ### are directory bits and which bits are file bits.  In this case we
         ### know the result should be a directory.  I had thought you could omit
         ### the file argument to catpath in such a case, but apparently on UNIX
         ### you can't.
         $dir        = File::Spec->catpath(
                             $cwd_vol, File::Spec->catdir( @cwd, @dirs ), ''
                         );
 
         ### catdir() returns undef if the path is longer than 255 chars on
         ### older VMS systems.
         unless ( defined $dir ) {
             $^W && $self->_error( qq[Could not compose a path for '$dirs'\n] );
             return;
         }
 
     }
 
     if( -e $dir && !-d _ ) {
         $^W && $self->_error( qq['$dir' exists, but it's not a directory!\n] );
         return;
     }
 
     unless ( -d _ ) {
         eval { File::Path::mkpath( $dir, 0, 0777 ) };
         if( $@ ) {
             my $fp = $entry->full_path;
             $self->_error(qq[Could not create directory '$dir' for '$fp': $@]);
             return;
         }
 
         ### XXX chown here? that might not be the same as in the archive
         ### as we're only chown'ing to the owner of the file we're extracting
         ### not to the owner of the directory itself, which may or may not
         ### be another entry in the archive
         ### Answer: no, gnu tar doesn't do it either, it'd be the wrong
         ### way to go.
         #if( $CHOWN && CAN_CHOWN ) {
         #    chown $entry->uid, $entry->gid, $dir or
         #        $self->_error( qq[Could not set uid/gid on '$dir'] );
         #}
     }
 
     ### we're done if we just needed to create a dir ###
     return 1 if $entry->is_dir;
 
     my $full = File::Spec->catfile( $dir, $file );
 
     if( $entry->is_unknown ) {
         $self->_error( qq[Unknown file type for file '$full'] );
         return;
     }
 
     if( length $entry->type && $entry->is_file ) {
         my $fh = IO::File->new;
         $fh->open( '>' . $full ) or (
             $self->_error( qq[Could not open file '$full': $!] ),
             return
         );
 
         if( $entry->size ) {
             binmode $fh;
             syswrite $fh, $entry->data or (
                 $self->_error( qq[Could not write data to '$full'] ),
                 return
             );
         }
 
         close $fh or (
             $self->_error( qq[Could not close file '$full'] ),
             return
         );
 
     } else {
         $self->_make_special_file( $entry, $full ) or return;
     }
 
     ### only update the timestamp if it's not a symlink; that will change the
     ### timestamp of the original. This addresses bug #33669: Could not update
     ### timestamp warning on symlinks
     if( not -l $full ) {
         utime time, $entry->mtime - TIME_OFFSET, $full or
             $self->_error( qq[Could not update timestamp] );
     }
 
     if( $CHOWN && CAN_CHOWN->() and not -l $full ) {
         chown $entry->uid, $entry->gid, $full or
             $self->_error( qq[Could not set uid/gid on '$full'] );
     }
 
     ### only chmod if we're allowed to, but never chmod symlinks, since they'll
     ### change the perms on the file they're linking too...
     if( $CHMOD and not -l $full ) {
         my $mode = $entry->mode;
         unless ($SAME_PERMISSIONS) {
             $mode &= ~(oct(7000) | umask);
         }
         chmod $mode, $full or
             $self->_error( qq[Could not chown '$full' to ] . $entry->mode );
     }
 
     return 1;
 }
 
 sub _make_special_file {
     my $self    = shift;
     my $entry   = shift     or return;
     my $file    = shift;    return unless defined $file;
 
     my $err;
 
     if( $entry->is_symlink ) {
         my $fail;
         if( ON_UNIX ) {
             symlink( $entry->linkname, $file ) or $fail++;
 
         } else {
             $self->_extract_special_file_as_plain_file( $entry, $file )
                 or $fail++;
         }
 
         $err =  qq[Making symbolic link '$file' to '] .
                 $entry->linkname .q[' failed] if $fail;
 
     } elsif ( $entry->is_hardlink ) {
         my $fail;
         if( ON_UNIX ) {
             link( $entry->linkname, $file ) or $fail++;
 
         } else {
             $self->_extract_special_file_as_plain_file( $entry, $file )
                 or $fail++;
         }
 
         $err =  qq[Making hard link from '] . $entry->linkname .
                 qq[' to '$file' failed] if $fail;
 
     } elsif ( $entry->is_fifo ) {
         ON_UNIX && !system('mknod', $file, 'p') or
             $err = qq[Making fifo ']. $entry->name .qq[' failed];
 
     } elsif ( $entry->is_blockdev or $entry->is_chardev ) {
         my $mode = $entry->is_blockdev ? 'b' : 'c';
 
         ON_UNIX && !system('mknod', $file, $mode,
                             $entry->devmajor, $entry->devminor) or
             $err =  qq[Making block device ']. $entry->name .qq[' (maj=] .
                     $entry->devmajor . qq[ min=] . $entry->devminor .
                     qq[) failed.];
 
     } elsif ( $entry->is_socket ) {
         ### the original doesn't do anything special for sockets.... ###
         1;
     }
 
     return $err ? $self->_error( $err ) : 1;
 }
 
 ### don't know how to make symlinks, let's just extract the file as
 ### a plain file
 sub _extract_special_file_as_plain_file {
     my $self    = shift;
     my $entry   = shift     or return;
     my $file    = shift;    return unless defined $file;
 
     my $err;
     TRY: {
         my $orig = $self->_find_entry( $entry->linkname );
 
         unless( $orig ) {
             $err =  qq[Could not find file '] . $entry->linkname .
                     qq[' in memory.];
             last TRY;
         }
 
         ### clone the entry, make it appear as a normal file ###
         my $clone = $entry->clone;
         $clone->_downgrade_to_plainfile;
         $self->_extract_file( $clone, $file ) or last TRY;
 
         return 1;
     }
 
     return $self->_error($err);
 }
 
 =head2 $tar->list_files( [\@properties] )
 
 Returns a list of the names of all the files in the archive.
 
 If C<list_files()> is passed an array reference as its first argument
 it returns a list of hash references containing the requested
 properties of each file.  The following list of properties is
 supported: name, size, mtime (last modified date), mode, uid, gid,
 linkname, uname, gname, devmajor, devminor, prefix.
 
 Passing an array reference containing only one element, 'name', is
 special cased to return a list of names rather than a list of hash
 references, making it equivalent to calling C<list_files> without
 arguments.
 
 =cut
 
 sub list_files {
     my $self = shift;
     my $aref = shift || [ ];
 
     unless( $self->_data ) {
         $self->read() or return;
     }
 
     if( @$aref == 0 or ( @$aref == 1 and $aref->[0] eq 'name' ) ) {
         return map { $_->full_path } @{$self->_data};
     } else {
 
         #my @rv;
         #for my $obj ( @{$self->_data} ) {
         #    push @rv, { map { $_ => $obj->$_() } @$aref };
         #}
         #return @rv;
 
         ### this does the same as the above.. just needs a +{ }
         ### to make sure perl doesn't confuse it for a block
         return map {    my $o=$_;
                         +{ map { $_ => $o->$_() } @$aref }
                     } @{$self->_data};
     }
 }
 
 sub _find_entry {
     my $self = shift;
     my $file = shift;
 
     unless( defined $file ) {
         $self->_error( qq[No file specified] );
         return;
     }
 
     ### it's an object already
     return $file if UNIVERSAL::isa( $file, 'Archive::Tar::File' );
 
     for my $entry ( @{$self->_data} ) {
         my $path = $entry->full_path;
         return $entry if $path eq $file;
     }
 
     $self->_error( qq[No such file in archive: '$file'] );
     return;
 }
 
 =head2 $tar->get_files( [@filenames] )
 
 Returns the C<Archive::Tar::File> objects matching the filenames
 provided. If no filename list was passed, all C<Archive::Tar::File>
 objects in the current Tar object are returned.
 
 Please refer to the C<Archive::Tar::File> documentation on how to
 handle these objects.
 
 =cut
 
 sub get_files {
     my $self = shift;
 
     return @{ $self->_data } unless @_;
 
     my @list;
     for my $file ( @_ ) {
         push @list, grep { defined } $self->_find_entry( $file );
     }
 
     return @list;
 }
 
 =head2 $tar->get_content( $file )
 
 Return the content of the named file.
 
 =cut
 
 sub get_content {
     my $self = shift;
     my $entry = $self->_find_entry( shift ) or return;
 
     return $entry->data;
 }
 
 =head2 $tar->replace_content( $file, $content )
 
 Make the string $content be the content for the file named $file.
 
 =cut
 
 sub replace_content {
     my $self = shift;
     my $entry = $self->_find_entry( shift ) or return;
 
     return $entry->replace_content( shift );
 }
 
 =head2 $tar->rename( $file, $new_name )
 
 Rename the file of the in-memory archive to $new_name.
 
 Note that you must specify a Unix path for $new_name, since per tar
 standard, all files in the archive must be Unix paths.
 
 Returns true on success and false on failure.
 
 =cut
 
 sub rename {
     my $self = shift;
     my $file = shift; return unless defined $file;
     my $new  = shift; return unless defined $new;
 
     my $entry = $self->_find_entry( $file ) or return;
 
     return $entry->rename( $new );
 }
 
 =head2 $tar->chmod( $file, $mode )
 
 Change mode of $file to $mode.
 
 Returns true on success and false on failure.
 
 =cut
 
 sub chmod {
     my $self = shift;
     my $file = shift; return unless defined $file;
     my $mode = shift; return unless defined $mode && $mode =~ /^[0-7]{1,4}$/;
     my @args = ("$mode");
 
     my $entry = $self->_find_entry( $file ) or return;
     my $x = $entry->chmod( @args );
     return $x;
 }
 
 =head2 $tar->chown( $file, $uname [, $gname] )
 
 Change owner $file to $uname and $gname.
 
 Returns true on success and false on failure.
 
 =cut
 
 sub chown {
     my $self = shift;
     my $file = shift; return unless defined $file;
     my $uname  = shift; return unless defined $uname;
     my @args   = ($uname);
     push(@args, shift);
 
     my $entry = $self->_find_entry( $file ) or return;
     my $x = $entry->chown( @args );
     return $x;
 }
 
 =head2 $tar->remove (@filenamelist)
 
 Removes any entries with names matching any of the given filenames
 from the in-memory archive. Returns a list of C<Archive::Tar::File>
 objects that remain.
 
 =cut
 
 sub remove {
     my $self = shift;
     my @list = @_;
 
     my %seen = map { $_->full_path => $_ } @{$self->_data};
     delete $seen{ $_ } for @list;
 
     $self->_data( [values %seen] );
 
     return values %seen;
 }
 
 =head2 $tar->clear
 
 C<clear> clears the current in-memory archive. This effectively gives
 you a 'blank' object, ready to be filled again. Note that C<clear>
 only has effect on the object, not the underlying tarfile.
 
 =cut
 
 sub clear {
     my $self = shift or return;
 
     $self->_data( [] );
     $self->_file( '' );
 
     return 1;
 }
 
 
 =head2 $tar->write ( [$file, $compressed, $prefix] )
 
 Write the in-memory archive to disk.  The first argument can either
 be the name of a file or a reference to an already open filehandle (a
 GLOB reference).
 
 The second argument is used to indicate compression. You can either
 compress using C<gzip> or C<bzip2>. If you pass a digit, it's assumed
 to be the C<gzip> compression level (between 1 and 9), but the use of
 constants is preferred:
 
   # write a gzip compressed file
   $tar->write( 'out.tgz', COMPRESS_GZIP );
 
   # write a bzip compressed file
   $tar->write( 'out.tbz', COMPRESS_BZIP );
 
 Note that when you pass in a filehandle, the compression argument
 is ignored, as all files are printed verbatim to your filehandle.
 If you wish to enable compression with filehandles, use an
 C<IO::Zlib> or C<IO::Compress::Bzip2> filehandle instead.
 
 The third argument is an optional prefix. All files will be tucked
 away in the directory you specify as prefix. So if you have files
 'a' and 'b' in your archive, and you specify 'foo' as prefix, they
 will be written to the archive as 'foo/a' and 'foo/b'.
 
 If no arguments are given, C<write> returns the entire formatted
 archive as a string, which could be useful if you'd like to stuff the
 archive into a socket or a pipe to gzip or something.
 
 
 =cut
 
 sub write {
     my $self        = shift;
     my $file        = shift; $file = '' unless defined $file;
     my $gzip        = shift || 0;
     my $ext_prefix  = shift; $ext_prefix = '' unless defined $ext_prefix;
     my $dummy       = '';
 
     ### only need a handle if we have a file to print to ###
     my $handle = length($file)
                     ? ( $self->_get_handle($file, $gzip, WRITE_ONLY->($gzip) )
                         or return )
                     : $HAS_PERLIO    ? do { open my $h, '>', \$dummy; $h }
                     : $HAS_IO_STRING ? IO::String->new
                     : __PACKAGE__->no_string_support();
 
     ### Addresses: #41798: Nonempty $\ when writing a TAR file produces a
     ### corrupt TAR file. Must clear out $\ to make sure no garbage is
     ### printed to the archive
     local $\;
 
     for my $entry ( @{$self->_data} ) {
         ### entries to be written to the tarfile ###
         my @write_me;
 
         ### only now will we change the object to reflect the current state
         ### of the name and prefix fields -- this needs to be limited to
         ### write() only!
         my $clone = $entry->clone;
 
 
         ### so, if you don't want use to use the prefix, we'll stuff
         ### everything in the name field instead
         if( $DO_NOT_USE_PREFIX ) {
 
             ### you might have an extended prefix, if so, set it in the clone
             ### XXX is ::Unix right?
             $clone->name( length $ext_prefix
                             ? File::Spec::Unix->catdir( $ext_prefix,
                                                         $clone->full_path)
                             : $clone->full_path );
             $clone->prefix( '' );
 
         ### otherwise, we'll have to set it properly -- prefix part in the
         ### prefix and name part in the name field.
         } else {
 
             ### split them here, not before!
             my ($prefix,$name) = $clone->_prefix_and_file( $clone->full_path );
 
             ### you might have an extended prefix, if so, set it in the clone
             ### XXX is ::Unix right?
             $prefix = File::Spec::Unix->catdir( $ext_prefix, $prefix )
                 if length $ext_prefix;
 
             $clone->prefix( $prefix );
             $clone->name( $name );
         }
 
         ### names are too long, and will get truncated if we don't add a
         ### '@LongLink' file...
         my $make_longlink = (   length($clone->name)    > NAME_LENGTH or
                                 length($clone->prefix)  > PREFIX_LENGTH
                             ) || 0;
 
         ### perhaps we need to make a longlink file?
         if( $make_longlink ) {
             my $longlink = Archive::Tar::File->new(
                             data => LONGLINK_NAME,
                             $clone->full_path,
                             { type => LONGLINK }
                         );
 
             unless( $longlink ) {
                 $self->_error(  qq[Could not create 'LongLink' entry for ] .
                                 qq[oversize file '] . $clone->full_path ."'" );
                 return;
             };
 
             push @write_me, $longlink;
         }
 
         push @write_me, $clone;
 
         ### write the one, optionally 2 a::t::file objects to the handle
         for my $clone (@write_me) {
 
             ### if the file is a symlink, there are 2 options:
             ### either we leave the symlink intact, but then we don't write any
             ### data OR we follow the symlink, which means we actually make a
             ### copy. if we do the latter, we have to change the TYPE of the
             ### clone to 'FILE'
             my $link_ok =  $clone->is_symlink && $Archive::Tar::FOLLOW_SYMLINK;
             my $data_ok = !$clone->is_symlink && $clone->has_content;
 
             ### downgrade to a 'normal' file if it's a symlink we're going to
             ### treat as a regular file
             $clone->_downgrade_to_plainfile if $link_ok;
 
             ### get the header for this block
             my $header = $self->_format_tar_entry( $clone );
             unless( $header ) {
                 $self->_error(q[Could not format header for: ] .
                                     $clone->full_path );
                 return;
             }
 
             unless( print $handle $header ) {
                 $self->_error(q[Could not write header for: ] .
                                     $clone->full_path);
                 return;
             }
 
             if( $link_ok or $data_ok ) {
                 unless( print $handle $clone->data ) {
                     $self->_error(q[Could not write data for: ] .
                                     $clone->full_path);
                     return;
                 }
 
                 ### pad the end of the clone if required ###
                 print $handle TAR_PAD->( $clone->size ) if $clone->size % BLOCK
             }
 
         } ### done writing these entries
     }
 
     ### write the end markers ###
     print $handle TAR_END x 2 or
             return $self->_error( qq[Could not write tar end markers] );
 
     ### did you want it written to a file, or returned as a string? ###
     my $rv =  length($file) ? 1
                         : $HAS_PERLIO ? $dummy
                         : do { seek $handle, 0, 0; local $/; <$handle> };
 
     ### make sure to close the handle if we created it
     if ( $file ne $handle ) {
 	unless( close $handle ) {
 	    $self->_error( qq[Could not write tar] );
 	    return;
 	}
     }
 
     return $rv;
 }
 
 sub _format_tar_entry {
     my $self        = shift;
     my $entry       = shift or return;
     my $ext_prefix  = shift; $ext_prefix = '' unless defined $ext_prefix;
     my $no_prefix   = shift || 0;
 
     my $file    = $entry->name;
     my $prefix  = $entry->prefix; $prefix = '' unless defined $prefix;
 
     ### remove the prefix from the file name
     ### not sure if this is still needed --kane
     ### no it's not -- Archive::Tar::File->_new_from_file will take care of
     ### this for us. Even worse, this would break if we tried to add a file
     ### like x/x.
     #if( length $prefix ) {
     #    $file =~ s/^$match//;
     #}
 
     $prefix = File::Spec::Unix->catdir($ext_prefix, $prefix)
                 if length $ext_prefix;
 
     ### not sure why this is... ###
     my $l = PREFIX_LENGTH; # is ambiguous otherwise...
     substr ($prefix, 0, -$l) = "" if length $prefix >= PREFIX_LENGTH;
 
     my $f1 = "%06o"; my $f2  = $ZERO_PAD_NUMBERS ? "%011o" : "%11o";
 
     ### this might be optimizable with a 'changed' flag in the file objects ###
     my $tar = pack (
                 PACK,
                 $file,
 
                 (map { sprintf( $f1, $entry->$_() ) } qw[mode uid gid]),
                 (map { sprintf( $f2, $entry->$_() ) } qw[size mtime]),
 
                 "",  # checksum field - space padded a bit down
 
                 (map { $entry->$_() }                 qw[type linkname magic]),
 
                 $entry->version || TAR_VERSION,
 
                 (map { $entry->$_() }                 qw[uname gname]),
                 (map { sprintf( $f1, $entry->$_() ) } qw[devmajor devminor]),
 
                 ($no_prefix ? '' : $prefix)
     );
 
     ### add the checksum ###
     my $checksum_fmt = $ZERO_PAD_NUMBERS ? "%06o\0" : "%06o\0";
     substr($tar,148,7) = sprintf("%6o\0", unpack("%16C*",$tar));
 
     return $tar;
 }
 
 =head2 $tar->add_files( @filenamelist )
 
 Takes a list of filenames and adds them to the in-memory archive.
 
 The path to the file is automatically converted to a Unix like
 equivalent for use in the archive, and, if on MacOS, the file's
 modification time is converted from the MacOS epoch to the Unix epoch.
 So tar archives created on MacOS with B<Archive::Tar> can be read
 both with I<tar> on Unix and applications like I<suntar> or
 I<Stuffit Expander> on MacOS.
 
 Be aware that the file's type/creator and resource fork will be lost,
 which is usually what you want in cross-platform archives.
 
 Instead of a filename, you can also pass it an existing C<Archive::Tar::File>
 object from, for example, another archive. The object will be clone, and
 effectively be a copy of the original, not an alias.
 
 Returns a list of C<Archive::Tar::File> objects that were just added.
 
 =cut
 
 sub add_files {
     my $self    = shift;
     my @files   = @_ or return;
 
     my @rv;
     for my $file ( @files ) {
 
         ### you passed an Archive::Tar::File object
         ### clone it so we don't accidentally have a reference to
         ### an object from another archive
         if( UNIVERSAL::isa( $file,'Archive::Tar::File' ) ) {
             push @rv, $file->clone;
             next;
         }
 
         eval {
             if( utf8::is_utf8( $file )) {
               utf8::encode( $file );
             }
         };
 
         unless( -e $file || -l $file ) {
             $self->_error( qq[No such file: '$file'] );
             next;
         }
 
         my $obj = Archive::Tar::File->new( file => $file );
         unless( $obj ) {
             $self->_error( qq[Unable to add file: '$file'] );
             next;
         }
 
         push @rv, $obj;
     }
 
     push @{$self->{_data}}, @rv;
 
     return @rv;
 }
 
 =head2 $tar->add_data ( $filename, $data, [$opthashref] )
 
 Takes a filename, a scalar full of data and optionally a reference to
 a hash with specific options.
 
 Will add a file to the in-memory archive, with name C<$filename> and
 content C<$data>. Specific properties can be set using C<$opthashref>.
 The following list of properties is supported: name, size, mtime
 (last modified date), mode, uid, gid, linkname, uname, gname,
 devmajor, devminor, prefix, type.  (On MacOS, the file's path and
 modification times are converted to Unix equivalents.)
 
 Valid values for the file type are the following constants defined by
 Archive::Tar::Constant:
 
 =over 4
 
 =item FILE
 
 Regular file.
 
 =item HARDLINK
 
 =item SYMLINK
 
 Hard and symbolic ("soft") links; linkname should specify target.
 
 =item CHARDEV
 
 =item BLOCKDEV
 
 Character and block devices. devmajor and devminor should specify the major
 and minor device numbers.
 
 =item DIR
 
 Directory.
 
 =item FIFO
 
 FIFO (named pipe).
 
 =item SOCKET
 
 Socket.
 
 =back
 
 Returns the C<Archive::Tar::File> object that was just added, or
 C<undef> on failure.
 
 =cut
 
 sub add_data {
     my $self    = shift;
     my ($file, $data, $opt) = @_;
 
     my $obj = Archive::Tar::File->new( data => $file, $data, $opt );
     unless( $obj ) {
         $self->_error( qq[Unable to add file: '$file'] );
         return;
     }
 
     push @{$self->{_data}}, $obj;
 
     return $obj;
 }
 
 =head2 $tar->error( [$BOOL] )
 
 Returns the current error string (usually, the last error reported).
 If a true value was specified, it will give the C<Carp::longmess>
 equivalent of the error, in effect giving you a stacktrace.
 
 For backwards compatibility, this error is also available as
 C<$Archive::Tar::error> although it is much recommended you use the
 method call instead.
 
 =cut
 
 {
     $error = '';
     my $longmess;
 
     sub _error {
         my $self    = shift;
         my $msg     = $error = shift;
         $longmess   = Carp::longmess($error);
         if (ref $self) {
             $self->{_error} = $error;
             $self->{_longmess} = $longmess;
         }
 
         ### set Archive::Tar::WARN to 0 to disable printing
         ### of errors
         if( $WARN ) {
             carp $DEBUG ? $longmess : $msg;
         }
 
         return;
     }
 
     sub error {
         my $self = shift;
         if (ref $self) {
             return shift() ? $self->{_longmess} : $self->{_error};
         } else {
             return shift() ? $longmess : $error;
         }
     }
 }
 
 =head2 $tar->setcwd( $cwd );
 
 C<Archive::Tar> needs to know the current directory, and it will run
 C<Cwd::cwd()> I<every> time it extracts a I<relative> entry from the
 tarfile and saves it in the file system. (As of version 1.30, however,
 C<Archive::Tar> will use the speed optimization described below
 automatically, so it's only relevant if you're using C<extract_file()>).
 
 Since C<Archive::Tar> doesn't change the current directory internally
 while it is extracting the items in a tarball, all calls to C<Cwd::cwd()>
 can be avoided if we can guarantee that the current directory doesn't
 get changed externally.
 
 To use this performance boost, set the current directory via
 
     use Cwd;
     $tar->setcwd( cwd() );
 
 once before calling a function like C<extract_file> and
 C<Archive::Tar> will use the current directory setting from then on
 and won't call C<Cwd::cwd()> internally.
 
 To switch back to the default behaviour, use
 
     $tar->setcwd( undef );
 
 and C<Archive::Tar> will call C<Cwd::cwd()> internally again.
 
 If you're using C<Archive::Tar>'s C<extract()> method, C<setcwd()> will
 be called for you.
 
 =cut
 
 sub setcwd {
     my $self     = shift;
     my $cwd      = shift;
 
     $self->{cwd} = $cwd;
 }
 
 =head1 Class Methods
 
 =head2 Archive::Tar->create_archive($file, $compressed, @filelist)
 
 Creates a tar file from the list of files provided.  The first
 argument can either be the name of the tar file to create or a
 reference to an open file handle (e.g. a GLOB reference).
 
 The second argument is used to indicate compression. You can either
 compress using C<gzip> or C<bzip2>. If you pass a digit, it's assumed
 to be the C<gzip> compression level (between 1 and 9), but the use of
 constants is preferred:
 
   # write a gzip compressed file
   Archive::Tar->create_archive( 'out.tgz', COMPRESS_GZIP, @filelist );
 
   # write a bzip compressed file
   Archive::Tar->create_archive( 'out.tbz', COMPRESS_BZIP, @filelist );
 
 Note that when you pass in a filehandle, the compression argument
 is ignored, as all files are printed verbatim to your filehandle.
 If you wish to enable compression with filehandles, use an
 C<IO::Zlib> or C<IO::Compress::Bzip2> filehandle instead.
 
 The remaining arguments list the files to be included in the tar file.
 These files must all exist. Any files which don't exist or can't be
 read are silently ignored.
 
 If the archive creation fails for any reason, C<create_archive> will
 return false. Please use the C<error> method to find the cause of the
 failure.
 
 Note that this method does not write C<on the fly> as it were; it
 still reads all the files into memory before writing out the archive.
 Consult the FAQ below if this is a problem.
 
 =cut
 
 sub create_archive {
     my $class = shift;
 
     my $file    = shift; return unless defined $file;
     my $gzip    = shift || 0;
     my @files   = @_;
 
     unless( @files ) {
         return $class->_error( qq[Cowardly refusing to create empty archive!] );
     }
 
     my $tar = $class->new;
     $tar->add_files( @files );
     return $tar->write( $file, $gzip );
 }
 
 =head2 Archive::Tar->iter( $filename, [ $compressed, {opt => $val} ] )
 
 Returns an iterator function that reads the tar file without loading
 it all in memory.  Each time the function is called it will return the
 next file in the tarball. The files are returned as
 C<Archive::Tar::File> objects. The iterator function returns the
 empty list once it has exhausted the files contained.
 
 The second argument can be a hash reference with options, which are
 identical to the arguments passed to C<read()>.
 
 Example usage:
 
     my $next = Archive::Tar->iter( "example.tar.gz", 1, {filter => qr/\.pm$/} );
 
     while( my $f = $next->() ) {
         print $f->name, "\n";
 
         $f->extract or warn "Extraction failed";
 
         # ....
     }
 
 =cut
 
 
 sub iter {
     my $class       = shift;
     my $filename    = shift or return;
     my $compressed  = shift || 0;
     my $opts        = shift || {};
 
     ### get a handle to read from.
     my $handle = $class->_get_handle(
         $filename,
         $compressed,
         READ_ONLY->( ZLIB )
     ) or return;
 
     my @data;
     return sub {
         return shift(@data)     if @data;       # more than one file returned?
         return                  unless $handle; # handle exhausted?
 
         ### read data, should only return file
         my $tarfile = $class->_read_tar($handle, { %$opts, limit => 1 });
         @data = @$tarfile if ref $tarfile && ref $tarfile eq 'ARRAY';
 
         ### return one piece of data
         return shift(@data)     if @data;
 
         ### data is exhausted, free the filehandle
         undef $handle;
         return;
     };
 }
 
 =head2 Archive::Tar->list_archive($file, $compressed, [\@properties])
 
 Returns a list of the names of all the files in the archive.  The
 first argument can either be the name of the tar file to list or a
 reference to an open file handle (e.g. a GLOB reference).
 
 If C<list_archive()> is passed an array reference as its third
 argument it returns a list of hash references containing the requested
 properties of each file.  The following list of properties is
 supported: full_path, name, size, mtime (last modified date), mode,
 uid, gid, linkname, uname, gname, devmajor, devminor, prefix, type.
 
 See C<Archive::Tar::File> for details about supported properties.
 
 Passing an array reference containing only one element, 'name', is
 special cased to return a list of names rather than a list of hash
 references.
 
 =cut
 
 sub list_archive {
     my $class   = shift;
     my $file    = shift; return unless defined $file;
     my $gzip    = shift || 0;
 
     my $tar = $class->new($file, $gzip);
     return unless $tar;
 
     return $tar->list_files( @_ );
 }
 
 =head2 Archive::Tar->extract_archive($file, $compressed)
 
 Extracts the contents of the tar file.  The first argument can either
 be the name of the tar file to create or a reference to an open file
 handle (e.g. a GLOB reference).  All relative paths in the tar file will
 be created underneath the current working directory.
 
 C<extract_archive> will return a list of files it extracted.
 If the archive extraction fails for any reason, C<extract_archive>
 will return false.  Please use the C<error> method to find the cause
 of the failure.
 
 =cut
 
 sub extract_archive {
     my $class   = shift;
     my $file    = shift; return unless defined $file;
     my $gzip    = shift || 0;
 
     my $tar = $class->new( ) or return;
 
     return $tar->read( $file, $gzip, { extract => 1 } );
 }
 
 =head2 $bool = Archive::Tar->has_io_string
 
 Returns true if we currently have C<IO::String> support loaded.
 
 Either C<IO::String> or C<perlio> support is needed to support writing
 stringified archives. Currently, C<perlio> is the preferred method, if
 available.
 
 See the C<GLOBAL VARIABLES> section to see how to change this preference.
 
 =cut
 
 sub has_io_string { return $HAS_IO_STRING; }
 
 =head2 $bool = Archive::Tar->has_perlio
 
 Returns true if we currently have C<perlio> support loaded.
 
 This requires C<perl-5.8> or higher, compiled with C<perlio>
 
 Either C<IO::String> or C<perlio> support is needed to support writing
 stringified archives. Currently, C<perlio> is the preferred method, if
 available.
 
 See the C<GLOBAL VARIABLES> section to see how to change this preference.
 
 =cut
 
 sub has_perlio { return $HAS_PERLIO; }
 
 =head2 $bool = Archive::Tar->has_zlib_support
 
 Returns true if C<Archive::Tar> can extract C<zlib> compressed archives
 
 =cut
 
 sub has_zlib_support { return ZLIB }
 
 =head2 $bool = Archive::Tar->has_bzip2_support
 
 Returns true if C<Archive::Tar> can extract C<bzip2> compressed archives
 
 =cut
 
 sub has_bzip2_support { return BZIP }
 
 =head2 Archive::Tar->can_handle_compressed_files
 
 A simple checking routine, which will return true if C<Archive::Tar>
 is able to uncompress compressed archives on the fly with C<IO::Zlib>
 and C<IO::Compress::Bzip2> or false if not both are installed.
 
 You can use this as a shortcut to determine whether C<Archive::Tar>
 will do what you think before passing compressed archives to its
 C<read> method.
 
 =cut
 
 sub can_handle_compressed_files { return ZLIB && BZIP ? 1 : 0 }
 
 sub no_string_support {
     croak("You have to install IO::String to support writing archives to strings");
 }
 
 1;
 
 __END__
 
 =head1 GLOBAL VARIABLES
 
 =head2 $Archive::Tar::FOLLOW_SYMLINK
 
 Set this variable to C<1> to make C<Archive::Tar> effectively make a
 copy of the file when extracting. Default is C<0>, which
 means the symlink stays intact. Of course, you will have to pack the
 file linked to as well.
 
 This option is checked when you write out the tarfile using C<write>
 or C<create_archive>.
 
 This works just like C</bin/tar>'s C<-h> option.
 
 =head2 $Archive::Tar::CHOWN
 
 By default, C<Archive::Tar> will try to C<chown> your files if it is
 able to. In some cases, this may not be desired. In that case, set
 this variable to C<0> to disable C<chown>-ing, even if it were
 possible.
 
 The default is C<1>.
 
 =head2 $Archive::Tar::CHMOD
 
 By default, C<Archive::Tar> will try to C<chmod> your files to
 whatever mode was specified for the particular file in the archive.
 In some cases, this may not be desired. In that case, set this
 variable to C<0> to disable C<chmod>-ing.
 
 The default is C<1>.
 
 =head2 $Archive::Tar::SAME_PERMISSIONS
 
 When, C<$Archive::Tar::CHMOD> is enabled, this setting controls whether
 the permissions on files from the archive are used without modification
 of if they are filtered by removing any setid bits and applying the
 current umask.
 
 The default is C<1> for the root user and C<0> for normal users.
 
 =head2 $Archive::Tar::DO_NOT_USE_PREFIX
 
 By default, C<Archive::Tar> will try to put paths that are over
 100 characters in the C<prefix> field of your tar header, as
 defined per POSIX-standard. However, some (older) tar programs
 do not implement this spec. To retain compatibility with these older
 or non-POSIX compliant versions, you can set the C<$DO_NOT_USE_PREFIX>
 variable to a true value, and C<Archive::Tar> will use an alternate
 way of dealing with paths over 100 characters by using the
 C<GNU Extended Header> feature.
 
 Note that clients who do not support the C<GNU Extended Header>
 feature will not be able to read these archives. Such clients include
 tars on C<Solaris>, C<Irix> and C<AIX>.
 
 The default is C<0>.
 
 =head2 $Archive::Tar::DEBUG
 
 Set this variable to C<1> to always get the C<Carp::longmess> output
 of the warnings, instead of the regular C<carp>. This is the same
 message you would get by doing:
 
     $tar->error(1);
 
 Defaults to C<0>.
 
 =head2 $Archive::Tar::WARN
 
 Set this variable to C<0> if you do not want any warnings printed.
 Personally I recommend against doing this, but people asked for the
 option. Also, be advised that this is of course not threadsafe.
 
 Defaults to C<1>.
 
 =head2 $Archive::Tar::error
 
 Holds the last reported error. Kept for historical reasons, but its
 use is very much discouraged. Use the C<error()> method instead:
 
     warn $tar->error unless $tar->extract;
 
 Note that in older versions of this module, the C<error()> method
 would return an effectively global value even when called an instance
 method as above. This has since been fixed, and multiple instances of
 C<Archive::Tar> now have separate error strings.
 
 =head2 $Archive::Tar::INSECURE_EXTRACT_MODE
 
 This variable indicates whether C<Archive::Tar> should allow
 files to be extracted outside their current working directory.
 
 Allowing this could have security implications, as a malicious
 tar archive could alter or replace any file the extracting user
 has permissions to. Therefor, the default is to not allow
 insecure extractions.
 
 If you trust the archive, or have other reasons to allow the
 archive to write files outside your current working directory,
 set this variable to C<true>.
 
 Note that this is a backwards incompatible change from version
 C<1.36> and before.
 
 =head2 $Archive::Tar::HAS_PERLIO
 
 This variable holds a boolean indicating if we currently have
 C<perlio> support loaded. This will be enabled for any perl
 greater than C<5.8> compiled with C<perlio>.
 
 If you feel strongly about disabling it, set this variable to
 C<false>. Note that you will then need C<IO::String> installed
 to support writing stringified archives.
 
 Don't change this variable unless you B<really> know what you're
 doing.
 
 =head2 $Archive::Tar::HAS_IO_STRING
 
 This variable holds a boolean indicating if we currently have
 C<IO::String> support loaded. This will be enabled for any perl
 that has a loadable C<IO::String> module.
 
 If you feel strongly about disabling it, set this variable to
 C<false>. Note that you will then need C<perlio> support from
 your perl to be able to  write stringified archives.
 
 Don't change this variable unless you B<really> know what you're
 doing.
 
 =head2 $Archive::Tar::ZERO_PAD_NUMBERS
 
 This variable holds a boolean indicating if we will create
 zero padded numbers for C<size>, C<mtime> and C<checksum>.
 The default is C<0>, indicating that we will create space padded
 numbers. Added for compatibility with C<busybox> implementations.
 
 =head1 FAQ
 
 =over 4
 
 =item What's the minimum perl version required to run Archive::Tar?
 
 You will need perl version 5.005_03 or newer.
 
 =item Isn't Archive::Tar slow?
 
 Yes it is. It's pure perl, so it's a lot slower then your C</bin/tar>
 However, it's very portable. If speed is an issue, consider using
 C</bin/tar> instead.
 
 =item Isn't Archive::Tar heavier on memory than /bin/tar?
 
 Yes it is, see previous answer. Since C<Compress::Zlib> and therefore
 C<IO::Zlib> doesn't support C<seek> on their filehandles, there is little
 choice but to read the archive into memory.
 This is ok if you want to do in-memory manipulation of the archive.
 
 If you just want to extract, use the C<extract_archive> class method
 instead. It will optimize and write to disk immediately.
 
 Another option is to use the C<iter> class method to iterate over
 the files in the tarball without reading them all in memory at once.
 
 =item Can you lazy-load data instead?
 
 In some cases, yes. You can use the C<iter> class method to iterate
 over the files in the tarball without reading them all in memory at once.
 
 =item How much memory will an X kb tar file need?
 
 Probably more than X kb, since it will all be read into memory. If
 this is a problem, and you don't need to do in memory manipulation
 of the archive, consider using the C<iter> class method, or C</bin/tar>
 instead.
 
 =item What do you do with unsupported filetypes in an archive?
 
 C<Unix> has a few filetypes that aren't supported on other platforms,
 like C<Win32>. If we encounter a C<hardlink> or C<symlink> we'll just
 try to make a copy of the original file, rather than throwing an error.
 
 This does require you to read the entire archive in to memory first,
 since otherwise we wouldn't know what data to fill the copy with.
 (This means that you cannot use the class methods, including C<iter>
 on archives that have incompatible filetypes and still expect things
 to work).
 
 For other filetypes, like C<chardevs> and C<blockdevs> we'll warn that
 the extraction of this particular item didn't work.
 
 =item I'm using WinZip, or some other non-POSIX client, and files are not being extracted properly!
 
 By default, C<Archive::Tar> is in a completely POSIX-compatible
 mode, which uses the POSIX-specification of C<tar> to store files.
 For paths greater than 100 characters, this is done using the
 C<POSIX header prefix>. Non-POSIX-compatible clients may not support
 this part of the specification, and may only support the C<GNU Extended
 Header> functionality. To facilitate those clients, you can set the
 C<$Archive::Tar::DO_NOT_USE_PREFIX> variable to C<true>. See the
 C<GLOBAL VARIABLES> section for details on this variable.
 
 Note that GNU tar earlier than version 1.14 does not cope well with
 the C<POSIX header prefix>. If you use such a version, consider setting
 the C<$Archive::Tar::DO_NOT_USE_PREFIX> variable to C<true>.
 
 =item How do I extract only files that have property X from an archive?
 
 Sometimes, you might not wish to extract a complete archive, just
 the files that are relevant to you, based on some criteria.
 
 You can do this by filtering a list of C<Archive::Tar::File> objects
 based on your criteria. For example, to extract only files that have
 the string C<foo> in their title, you would use:
 
     $tar->extract(
         grep { $_->full_path =~ /foo/ } $tar->get_files
     );
 
 This way, you can filter on any attribute of the files in the archive.
 Consult the C<Archive::Tar::File> documentation on how to use these
 objects.
 
 =item How do I access .tar.Z files?
 
 The C<Archive::Tar> module can optionally use C<Compress::Zlib> (via
 the C<IO::Zlib> module) to access tar files that have been compressed
 with C<gzip>. Unfortunately tar files compressed with the Unix C<compress>
 utility cannot be read by C<Compress::Zlib> and so cannot be directly
 accesses by C<Archive::Tar>.
 
 If the C<uncompress> or C<gunzip> programs are available, you can use
 one of these workarounds to read C<.tar.Z> files from C<Archive::Tar>
 
 Firstly with C<uncompress>
 
     use Archive::Tar;
 
     open F, "uncompress -c $filename |";
     my $tar = Archive::Tar->new(*F);
     ...
 
 and this with C<gunzip>
 
     use Archive::Tar;
 
     open F, "gunzip -c $filename |";
     my $tar = Archive::Tar->new(*F);
     ...
 
 Similarly, if the C<compress> program is available, you can use this to
 write a C<.tar.Z> file
 
     use Archive::Tar;
     use IO::File;
 
     my $fh = new IO::File "| compress -c >$filename";
     my $tar = Archive::Tar->new();
     ...
     $tar->write($fh);
     $fh->close ;
 
 =item How do I handle Unicode strings?
 
 C<Archive::Tar> uses byte semantics for any files it reads from or writes
 to disk. This is not a problem if you only deal with files and never
 look at their content or work solely with byte strings. But if you use
 Unicode strings with character semantics, some additional steps need
 to be taken.
 
 For example, if you add a Unicode string like
 
     # Problem
     $tar->add_data('file.txt', "Euro: \x{20AC}");
 
 then there will be a problem later when the tarfile gets written out
 to disk via C<$tar->write()>:
 
     Wide character in print at .../Archive/Tar.pm line 1014.
 
 The data was added as a Unicode string and when writing it out to disk,
 the C<:utf8> line discipline wasn't set by C<Archive::Tar>, so Perl
 tried to convert the string to ISO-8859 and failed. The written file
 now contains garbage.
 
 For this reason, Unicode strings need to be converted to UTF-8-encoded
 bytestrings before they are handed off to C<add_data()>:
 
     use Encode;
     my $data = "Accented character: \x{20AC}";
     $data = encode('utf8', $data);
 
     $tar->add_data('file.txt', $data);
 
 A opposite problem occurs if you extract a UTF8-encoded file from a
 tarball. Using C<get_content()> on the C<Archive::Tar::File> object
 will return its content as a bytestring, not as a Unicode string.
 
 If you want it to be a Unicode string (because you want character
 semantics with operations like regular expression matching), you need
 to decode the UTF8-encoded content and have Perl convert it into
 a Unicode string:
 
     use Encode;
     my $data = $tar->get_content();
 
     # Make it a Unicode string
     $data = decode('utf8', $data);
 
 There is no easy way to provide this functionality in C<Archive::Tar>,
 because a tarball can contain many files, and each of which could be
 encoded in a different way.
 
 =back
 
 =head1 CAVEATS
 
 The AIX tar does not fill all unused space in the tar archive with 0x00.
 This sometimes leads to warning messages from C<Archive::Tar>.
 
   Invalid header block at offset nnn
 
 A fix for that problem is scheduled to be released in the following levels
 of AIX, all of which should be coming out in the 4th quarter of 2009:
 
  AIX 5.3 TL7 SP10
  AIX 5.3 TL8 SP8
  AIX 5.3 TL9 SP5
  AIX 5.3 TL10 SP2
 
  AIX 6.1 TL0 SP11
  AIX 6.1 TL1 SP7
  AIX 6.1 TL2 SP6
  AIX 6.1 TL3 SP3
 
 The IBM APAR number for this problem is IZ50240 (Reported component ID:
 5765G0300 / AIX 5.3). It is possible to get an ifix for that problem.
 If you need an ifix please contact your local IBM AIX support.
 
 =head1 TODO
 
 =over 4
 
 =item Check if passed in handles are open for read/write
 
 Currently I don't know of any portable pure perl way to do this.
 Suggestions welcome.
 
 =item Allow archives to be passed in as string
 
 Currently, we only allow opened filehandles or filenames, but
 not strings. The internals would need some reworking to facilitate
 stringified archives.
 
 =item Facilitate processing an opened filehandle of a compressed archive
 
 Currently, we only support this if the filehandle is an IO::Zlib object.
 Environments, like apache, will present you with an opened filehandle
 to an uploaded file, which might be a compressed archive.
 
 =back
 
 =head1 SEE ALSO
 
 =over 4
 
 =item The GNU tar specification
 
 C<http://www.gnu.org/software/tar/manual/tar.html>
 
 =item The PAX format specification
 
 The specification which tar derives from; C< http://www.opengroup.org/onlinepubs/007904975/utilities/pax.html>
 
 =item A comparison of GNU and POSIX tar standards; C<http://www.delorie.com/gnu/docs/tar/tar_114.html>
 
 =item GNU tar intends to switch to POSIX compatibility
 
 GNU Tar authors have expressed their intention to become completely
 POSIX-compatible; C<http://www.gnu.org/software/tar/manual/html_node/Formats.html>
 
 =item A Comparison between various tar implementations
 
 Lists known issues and incompatibilities; C<http://gd.tuwien.ac.at/utils/archivers/star/README.otherbugs>
 
 =back
 
 =head1 AUTHOR
 
 This module by Jos Boumans E<lt>kane@cpan.orgE<gt>.
 
 Please reports bugs to E<lt>bug-archive-tar@rt.cpan.orgE<gt>.
 
 =head1 ACKNOWLEDGEMENTS
 
 Thanks to Sean Burke, Chris Nandor, Chip Salzenberg, Tim Heaney, Gisle Aas,
 Rainer Tammer and especially Andrew Savige for their help and suggestions.
 
 =head1 COPYRIGHT
 
 This module is copyright (c) 2002 - 2009 Jos Boumans
 E<lt>kane@cpan.orgE<gt>. All rights reserved.
 
 This library is free software; you may redistribute and/or modify
 it under the same terms as Perl itself.
 
 =cut

END_OF_FILE

      'Archive/Tar/Constant.pm' => <<'END_OF_FILE',
 package Archive::Tar::Constant;
 
 BEGIN {
     require Exporter;
 
     $VERSION    = '1.92';
     @ISA        = qw[Exporter];
 
     require Time::Local if $^O eq "MacOS";
 }
 
 use Package::Constants;
 @EXPORT = Package::Constants->list( __PACKAGE__ );
 
 use constant FILE           => 0;
 use constant HARDLINK       => 1;
 use constant SYMLINK        => 2;
 use constant CHARDEV        => 3;
 use constant BLOCKDEV       => 4;
 use constant DIR            => 5;
 use constant FIFO           => 6;
 use constant SOCKET         => 8;
 use constant UNKNOWN        => 9;
 use constant LONGLINK       => 'L';
 use constant LABEL          => 'V';
 
 use constant BUFFER         => 4096;
 use constant HEAD           => 512;
 use constant BLOCK          => 512;
 
 use constant COMPRESS_GZIP  => 9;
 use constant COMPRESS_BZIP  => 'bzip2';
 
 use constant BLOCK_SIZE     => sub { my $n = int($_[0]/BLOCK); $n++ if $_[0] % BLOCK; $n * BLOCK };
 use constant TAR_PAD        => sub { my $x = shift || return; return "\0" x (BLOCK - ($x % BLOCK) ) };
 use constant TAR_END        => "\0" x BLOCK;
 
 use constant READ_ONLY      => sub { shift() ? 'rb' : 'r' };
 use constant WRITE_ONLY     => sub { $_[0] ? 'wb' . shift : 'w' };
 use constant MODE_READ      => sub { $_[0] =~ /^r/ ? 1 : 0 };
 
 # Pointless assignment to make -w shut up
 my $getpwuid; $getpwuid = 'unknown' unless eval { my $f = getpwuid (0); };
 my $getgrgid; $getgrgid = 'unknown' unless eval { my $f = getgrgid (0); };
 use constant UNAME          => sub { $getpwuid || scalar getpwuid( shift() ) || '' };
 use constant GNAME          => sub { $getgrgid || scalar getgrgid( shift() ) || '' };
 use constant UID            => $>;
 use constant GID            => (split ' ', $) )[0];
 
 use constant MODE           => do { 0666 & (0777 & ~umask) };
 use constant STRIP_MODE     => sub { shift() & 0777 };
 use constant CHECK_SUM      => "      ";
 
 use constant UNPACK         => 'A100 A8 A8 A8 a12 A12 A8 A1 A100 A6 A2 A32 A32 A8 A8 A155 x12';	# cdrake - size must be a12 - not A12 - or else screws up huge file sizes (>8gb)
 use constant PACK           => 'a100 a8 a8 a8 a12 a12 A8 a1 a100 a6 a2 a32 a32 a8 a8 a155 x12';
 use constant NAME_LENGTH    => 100;
 use constant PREFIX_LENGTH  => 155;
 
 use constant TIME_OFFSET    => ($^O eq "MacOS") ? Time::Local::timelocal(0,0,0,1,0,70) : 0;
 use constant MAGIC          => "ustar";
 use constant TAR_VERSION    => "00";
 use constant LONGLINK_NAME  => '././@LongLink';
 use constant PAX_HEADER     => 'pax_global_header';
 
                             ### allow ZLIB to be turned off using ENV: DEBUG only
 use constant ZLIB           => do { !$ENV{'PERL5_AT_NO_ZLIB'} and
                                         eval { require IO::Zlib };
                                     $ENV{'PERL5_AT_NO_ZLIB'} || $@ ? 0 : 1
                                 };
 
                             ### allow BZIP to be turned off using ENV: DEBUG only
 use constant BZIP           => do { !$ENV{'PERL5_AT_NO_BZIP'} and
                                         eval { require IO::Uncompress::Bunzip2;
                                                require IO::Compress::Bzip2; };
                                     $ENV{'PERL5_AT_NO_BZIP'} || $@ ? 0 : 1
                                 };
 
 use constant GZIP_MAGIC_NUM => qr/^(?:\037\213|\037\235)/;
 use constant BZIP_MAGIC_NUM => qr/^BZh\d/;
 
 use constant CAN_CHOWN      => sub { ($> == 0 and $^O ne "MacOS" and $^O ne "MSWin32") };
 use constant CAN_READLINK   => ($^O ne 'MSWin32' and $^O !~ /RISC(?:[ _])?OS/i and $^O ne 'VMS');
 use constant ON_UNIX        => ($^O ne 'MSWin32' and $^O ne 'MacOS' and $^O ne 'VMS');
 use constant ON_VMS         => $^O eq 'VMS';
 
 1;

END_OF_FILE

   );

   unshift @INC, sub {
      my ($me, $packfile) = @_;
      return unless exists $file_for{$packfile};
      (my $text = $file_for{$packfile}) =~ s/^\ //gmxs;
      chop($text); # added \n at the end
      open my $fh, '<', \$text or die "open(): $!\n";
      return $fh;
   };
} ## end BEGIN
# __MOBUNDLE_INCLUSION__

# *** NOTE *** LEAVE EMPTY LINE ABOVE
my %default_config = (    # default values
   workdir     => '/tmp/our-deploy',
   cleanup     => 1,
   'no-exec'   => 0,
   tempdir     => 1,
   passthrough => 0,
   verbose     => 0,
);

my $DATA_POSITION = tell DATA; # GLOBAL VARIABLE
my %script_config = (%default_config, get_config());

my %config = %script_config;
if ($ENV{DEPLOYABLE_DISABLE_PASSTHROUGH} || (! $config{passthrough})) {
   my %cmdline_config;
   GetOptions(
      \%cmdline_config,
      qw(
      usage|help|man!
      version!

      bundle|all-exec|X!
      cleanup|c!
      dryrun|dry-run|n!
      filelist|list|l!
      heretar|here-tar|H!
      inspect|i=s
      no-exec!
      no-tar!
      roottar|root-tar|R!
      show|show-options|s!
      tar|t=s
      tempdir!
      verbose!
      workdir|work-directory|deploy-directory|w=s
      ),
   ) or short_usage();
   %config = (%config, %cmdline_config);
}

usage()   if $config{usage};
version() if $config{version};

if ($config{roottar}) {
   binmode STDOUT;
   my ($fh, $size) = locate_file('root');
   copy($fh, \*STDOUT, $size);
   exit 0;
} ## end if ($config{roottar})

if ($config{heretar}) {
   binmode STDOUT;
   my ($fh, $size) = locate_file('here');
   copy($fh, \*STDOUT, $size);
   exit 0;
} ## end if ($config{heretar})

if ($config{show}) {
   require Data::Dumper;
   print {*STDOUT} Data::Dumper::Dumper(\%script_config);
   exit 1;
}

if ($config{inspect}) {
   $config{cleanup}   = 0;
   $config{'deploy'}  = 0;
   $config{'tempdir'} = 0;
   $config{workdir}   = $config{inspect};
} ## end if ($config{inspect})

if ($config{dryrun}) {
   require Data::Dumper;
   print {*STDOUT} Data::Dumper::Dumper(\%config);
   exit 1;
}

if ($config{filelist}) {
   my $root_tar = get_sub_tar('root');
   print "root:\n";
   $root_tar->print_filelist();
   my $here_tar = get_sub_tar('here');
   print "here:\n";
   $here_tar->print_filelist();
   exit 0;
} ## end if ($config{filelist})

# go into the working directory, creating any intermediate if needed
mkpath($config{workdir});
chdir($config{workdir});
print {*STDERR} "### Got into working directory '$config{workdir}'\n\n"
   if $config{verbose};

my $tempdir;
if ($config{'tempdir'}) {    # Only if allowed
   my $now = strftime('%Y-%m-%d_%H-%M-%S', localtime);
   $tempdir =
     tempdir($now . 'X' x 10, DIR => '.', CLEANUP => $config{cleanup});

   chdir $tempdir
     or die "chdir('$tempdir'): $OS_ERROR\n";

   if ($config{verbose}) {
      print {*STDERR}
        "### Created and got into temporary directory '$tempdir'\n";
      print {*STDERR} "### (will clean it up later)\n" if $config{cleanup};
      print {*STDERR} "\n";
   }
} ## end if ($config{'tempdir'})

eval {                       # Not really needed, but you know...
   $ENV{PATH} = '/bin:/usr/bin:/sbin:/usr/sbin';
   save_files();
   execute_deploy_programs() unless $config{'no-exec'};
};
warn "$EVAL_ERROR\n" if $EVAL_ERROR;

# Get back so that cleanup can successfully happen, if requested
chdir '..' if defined $tempdir;


sub locate_file {
   my ($filename) = @_;
   my $fh = \*DATA;
   seek $fh, $DATA_POSITION, SEEK_SET;
   while (! eof $fh) {
      chomp(my $sizes = <$fh>);
      my ($name_size, $file_size) = split /\s+/, $sizes;
      my $name = full_read($fh, $name_size);
      full_read($fh, 1); # "\n"
      return ($fh, $file_size) if $name eq $filename;
      seek $fh, $file_size + 2, SEEK_CUR; # includes "\n\n"
   }
   die "could not find '$filename'";
}

sub full_read {
   my ($fh, $size) = @_;
   my $retval = '';
   while ($size) {
      my $buffer;
      my $nread = read $fh, $buffer, $size;
      die "read(): $OS_ERROR" unless defined $nread;
      die "unexpected end of file" unless $nread;
      $retval .= $buffer;
      $size -= $nread;
   }
   return $retval;
}

sub copy {
   my ($ifh, $ofh, $size) = @_;
   while ($size) {
      my $buffer;
      my $nread = read $ifh, $buffer, ($size < 4096 ? $size : 4096);
      die "read(): $OS_ERROR" unless defined $nread;
      die "unexpected end of file" unless $nread;
      print {$ofh} $buffer;
      $size -= $nread;
   }
   return;
}

sub get_sub_tar {
   my ($filename) = @_;
   my ($fh, $size) = locate_file($filename);
   return Deployable::Tar->new(%config, fh => $fh, size => $size);
} ## end sub get_sub_tar

sub get_config {
   my ($fh, $size) = locate_file('config.pl');
   my $config_text = full_read($fh, $size);
   my $config = eval 'my ' . $config_text or return;
   return $config unless wantarray;
   return %$config;
} ## end sub get_config

sub save_files {
   my $here_tar = get_sub_tar('here');
   $here_tar->extract();

   my $root_dir = $config{inspect} ? 'root' : '/';
   mkpath $root_dir unless -d $root_dir;
   my $cwd = getcwd();
   chdir $root_dir;
   my $root_tar = get_sub_tar('root');
   $root_tar->extract();
   chdir $cwd;

   return;
} ## end sub save_files

sub execute_deploy_programs {
   my @deploy_programs = @{$config{deploy} || []};

   if ($config{bundle}) { # add all executable scripts in current directory
      print {*STDERR} "### Auto-deploying all executables in main dir\n\n"
         if $config{verbose};
      my %flag_for = map { $_ => 1 } @deploy_programs;
      opendir my $dh, '.';
      for my $item (sort readdir $dh) {
         next if $flag_for{$item};
         next unless ((-f $item) || (-l $item)) && (-x $item);
         $flag_for{$item} = 1;
         push @deploy_programs, $item;
      } ## end for my $item (sort readdir...
      closedir $dh;
   } ## end if ($config{bundle})

 DEPLOY:
   for my $deploy (@deploy_programs) {
      $deploy = catfile('.', $deploy)
        unless file_name_is_absolute($deploy);
      if (!-x $deploy) {
         print {*STDERR} "### Skipping '$deploy', not executable\n\n"
            if $config{verbose};
         next DEPLOY;
      }
      print  {*STDERR} "### Executing '$deploy'...\n"
         if $config{verbose};
      system {$deploy} $deploy, @ARGV;
      print  {*STDERR} "\n"
         if $config{verbose};
   } ## end for my $deploy (@deploy_programs)

   return;
} ## end sub execute_deploy_programs

sub short_usage {
   my $progname = basename($0);
   print {*STDOUT} <<"END_OF_USAGE" ;

$progname version $VERSION - for help on calling and options, run:

   $0 --usage
END_OF_USAGE
   exit 1;
}

sub usage {
   my $progname = basename($0);
   print {*STDOUT} <<"END_OF_USAGE" ;
$progname version $VERSION

More or less, this script is intended to be launched without parameters.
Anyway, you can also set the following options, which will override any
present configuration (except in "--show-options"):

* --usage | --man | --help
    print these help lines and exit

* --version
    print script version and exit

* --bundle | --all-exec | -X
    treat all executables in the main deployment directory as scripts
    to be executed

* --cleanup | -c | --no-cleanup
    perform / don't perform temporary directory cleanup after work done

* --deploy | --no-deploy
    deploy scripts are executed by default (same as specifying '--deploy')
    but you can prevent it.

* --dryrun | --dry-run
    print final options and exit

* --filelist | --list | -l
    print a list of files that are shipped in the deploy script

* --heretar | --here-tar | -H
    print out the tar file that contains all the files that would be
    extracted in the temporary directory, useful to redirect to file or
    pipe to the tar program

* --inspect | -i <dirname>
    just extract all the stuff into <dirname> for inspection. Implies
    --no-deploy, --no-tempdir, ignores --bundle (as a consequence of
    --no-deploy), disables --cleanup and sets the working directory
    to <dirname>

* --no-tar
    don't use system "tar"

* --roottar | --root-tar | -R
    print out the tar file that contains all the files that would be
    extracted in the root directory, useful to redirect to file or
    pipe to the tar program

* --show | --show-options | -s
    print configured options and exit

* --tar | -t <program-path>
    set the system "tar" program to use.

* --tempdir | --no-tempdir
    by default a temporary directory is created (same as specifying
    '--tempdir'), but you can execute directly in the workdir (see below)
    without creating it.

* --workdir | --work-directory | --deploy-directory | -w
    working base directory (a temporary subdirectory will be created 
    there anyway)
    
END_OF_USAGE
   exit 1;
} ## end sub usage

sub version {
   print "$0 version $VERSION\n";
   exit 1;
}


package Deployable::Tar;

sub new {
   my $package = shift;
   my $self = { ref $_[0] ? %{$_[0]} : @_ };
   $package = 'Deployable::Tar::Internal';
   if (! $self->{'no-tar'}) {
      if ((exists $self->{tar}) || (open my $fh, '-|', 'tar', '--help')) {
         $package = 'Deployable::Tar::External';
         $self->{tar} ||= 'tar';
      }
   }
   bless $self, $package;
   $self->initialise() if $self->can('initialise');
   return $self;
}

package Deployable::Tar::External;
use English qw( -no_match_vars );

sub initialise {
   my $self = shift;
   my $compression = $self->{bzip2} ? 'j'
      : $self->{gzip} ? 'z'
      :                 '';
   $self->{_list_command} = 'tv' . $compression . 'f';
   $self->{_extract_command} = 'x' . $compression . 'f';
}

sub print_filelist {
   my $self = shift;
   if ($self->{size}) {
      open my $tfh, '|-', $self->{tar}, $self->{_list_command}, '-'
         or die "open() on pipe to tar: $OS_ERROR";
      main::copy($self->{fh}, $tfh, $self->{size});
   }
   return $self;
}

sub extract {
   my $self = shift;
   if ($self->{size}) {
      open my $tfh, '|-', $self->{tar}, $self->{_extract_command}, '-'
         or die "open() on pipe to tar: $OS_ERROR";
      main::copy($self->{fh}, $tfh, $self->{size});
   }
   return $self;
}

package Deployable::Tar::Internal;
use English qw( -no_match_vars );

sub initialise {
   my $self = shift;

   if ($self->{size}) {
      my $data = main::full_read($self->{fh}, $self->{size});
      open my $fh, '<', \$data or die "open() on internal variable: $OS_ERROR";

      require Archive::Tar;
      $self->{_tar} = Archive::Tar->new();
      $self->{_tar}->read($fh);
   }

   return $self;
}

sub print_filelist {
   my $self = shift;
   if ($self->{size}) {
      print {*STDOUT} "   $_\n" for $self->{_tar}->list_files();
   }
   return $self;
}

sub extract {
   my $self = shift;
   if ($self->{size}) {
      $self->{_tar}->extract();
   }
   return $self;
}

__END__
