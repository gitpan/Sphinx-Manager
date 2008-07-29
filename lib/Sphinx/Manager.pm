package Sphinx::Manager;

use warnings;
use strict;
use base qw/Class::Accessor::Fast/;

use Carp qw/croak/;
use Proc::ProcessTable;
use Path::Class;
use File::Spec;
use Sphinx::Config;
use Errno qw/ECHILD/;

__PACKAGE__->mk_accessors(qw/config_file 
			  pid_file 
			  bindir 
			  searchd_args 
			  indexer_args 
			  process_timeout 
			  debug/);

my $default_config_file = 'sphinx.conf';
my $default_process_timeout = 10;

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);

    $self->debug(0) unless $self->debug;
    $self->config_file($default_config_file) unless $self->config_file;
    $self->process_timeout($default_process_timeout) unless $self->process_timeout;
    
    return $self;
}

# Determines pid_file from explicitly given file or by reading the config
sub _find_pidfile {
    my $self = shift;

    my $config_file = $self->config_file || $default_config_file;

    if (my $file = $self->pid_file) {
	return $self->{_pid_file} = Path::Class::file($file);
    }
    if ($self->{_config_file} && $config_file eq $self->{_config_file}) {
	# Config file unchanged
	return $self->{_pid_file} if $self->{_pid_file};
    }
    $self->_load_config_file;
    return $self->{_pid_file};
}

# Loads given config file and extracts the pid_file
sub _load_config_file {
    my $self = shift;

    my $config_file = $self->config_file || $default_config_file;

    my $config = Sphinx::Config->new;
    $config->parse($config_file);
    if (my $pid_file = $config->get('searchd', undef, 'pid_file')) {
	$self->{_pid_file} = Path::Class::file($pid_file);
    }
    $self->{_config_file} = Path::Class::file($config_file); # records which file we have loaded
}

# Find executable file
sub _find_exe {
    my $self = shift;
    my $name = shift;

    return Path::Class::file($self->bindir, $name) if $self->bindir;

    my @candidates = map { Path::Class::file($_, $name) } File::Spec->path();
    for my $bin (@candidates) {
	return $bin if -x "$bin";
    }
    die "Failed to find $name binary in bindir or system path; please specify bindir correctly";
}

# Find a process for given pid; return the PID if the process matches the given pattern
# If pid is not given, returns all process IDs matching the pattern
sub _findproc {
    my ($self, $pid, $pat) = @_;

    my $t = Proc::ProcessTable->new;

    if ($pid) {
	my $process;
	for (@{$t->table}) {
	    $process = $_, last if $_->pid == $pid;
	}
	return [ $pid ] if $process;
    }
    else {
	my @procs;
	for (@{$t->table}) {
	    my $cmndline = $_->{cmndline} || $_->{fname};
	    warn "Checking $cmndline against $pat" if $self->debug > 2;
	    push(@procs, $_->pid) if $cmndline =~ /$pat/;
	}
	return \@procs;
    }

    return [];
}

# Waits for a PID to disappear from the process table; returns 1 if found, 0 if timeout.
sub _wait_for_death {
    my $self = shift;
    my $pid = shift;
    my $timeout = $self->process_timeout || $default_process_timeout;

    my $ret = 0;
    my $t = time() + $timeout;
    while (time() < $t) {
	$ret++, last unless @{$self->_findproc($pid)};
	sleep(1);
    }
    return $ret;
}

# Waits for a process matching a given pattern to appear in the process table; returns 1 if found, 0 if timeout.
sub _wait_for_proc {
    my $self = shift;
    my $pat = shift;
    my $timeout = $self->process_timeout || $default_process_timeout;

    my $ret = 0;
    my $t = time() + $timeout;
    while (time() < $t) {
	$ret++, last if @{$self->_findproc(undef, $pat)};
	sleep(1);
    }
    return $ret;
}

sub _system_with_status
{
    my ($command) = @_;

    local $SIG{CHLD} = 'IGNORE';
    my $status = system($command);
    unless ($status == 0) {
        if ($? == -1) {
	    return '' if $! == ECHILD;
            return "$command failed to execute: $!";
        }
        if ($? & 127) {
            return sprintf("$command died with signal %d, %s coredump\n",
                           ($? & 127),  ($? & 128) ? 'with' : 'without');
        }
        return sprintf("$command exited with value %d\n", $? >> 8);
    }
    return '';
}

# Get regexp for matching command line
sub _get_searchd_matchre {
    my $self = shift;
    my $c = $self->{_config_file}->stringify;
    return qr/searchd.*(?:\s|=)$c(?:$|\s)/;
}

sub get_searchd_pid {
    my $self = shift;

    my $pids = [];
    my $pidfile = $self->_find_pidfile;
    if ( -f "$pidfile" ) {
	if (my $pid = $pidfile->slurp(chomp => 1)) {
	    push(@$pids, $pid) if @{$self->_findproc($pid, 'searchd')};
	}
    }
    if (! @$pids) {
	# backup plan if PID file is empty or invalid
	$pids = $self->_findproc(undef, $self->_get_searchd_matchre);
    }
    warn("Found searchd pid " . join(", ", @$pids)) if $self->debug;
    return $pids;
}

sub start_searchd {
    my $self = shift;

    my $pidfile = $self->_find_pidfile;
    warn "start_searchd: Checking pidfile $pidfile" if $self->debug;

    if ( -f "$pidfile" ) {
	my $pid = Path::Class::file($pidfile)->slurp(chomp => 1);
	warn "start_searchd: Found PID $pid" if $self->debug;
	die "searchd is already running" if $pid && @{$self->_findproc($pid, qr/searchd/)};
    }

    my $searchd = $self->_find_exe('searchd');
    my @args = ("--config", $self->{_config_file}->stringify);
    push(@args, @{$self->searchd_args}) if $self->searchd_args;
    warn("Executing $searchd " . join(" ", @args)) if $self->debug;

    local $SIG{CHLD} = 'IGNORE';
    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;
    if ($pid == 0) {
	fork() and exit; # double fork to ensure detach
	exec("$searchd", @args)
	    or die("Failed to exec $searchd}: $!");
    }

    die "Searchd not running after timeout" 
	unless $self->_wait_for_proc($self->_get_searchd_matchre);

}

sub stop_searchd {
    my $self = shift;

    my $pids = $self->get_searchd_pid;
    if (@$pids) {
	kill 15, @$pids;
	unless ($self->_wait_for_death(@$pids)) {
	    kill 9, @$pids;
	    unless ($self->_wait_for_death(@$pids)) {
		die "Failed to stop searchd PID " . join(", ", @$pids) . ", even with sure kill";
	    }
	}
    }
    # nothing found to kill so assume success
}

sub restart_searchd {
    my $self = shift;
    $self->stop_searchd;
    $self->start_searchd;
}

sub reload_searchd {
    my $self = shift;
    
    my $pids = $self->get_searchd_pid;
    if (@$pids) {
	# send HUP
	kill 1, @$pids;
    }
    else {
	$self->start_searchd;
    }
}

sub run_indexer {
    my $self = shift;
    my @extra_args = @_;

    my $indexer = $self->_find_exe('indexer');
    warn("Using indexer $indexer") if $self->debug;
    die "Cannot execute Sphinx indexer binary $indexer" unless -x "$indexer";

    my $config = $self->config_file || $default_config_file;
    my $cmd = "$indexer --config $config";
    $cmd .= ' ' . join(" ", @{$self->indexer_args}) if $self->indexer_args;
    $cmd .= ' ' . join(" ", @extra_args) if @extra_args;

    if (my $status = _system_with_status($cmd)) {
	die $status;
    }
}

=head1 NAME

Sphinx::Manager - Sphinx search engine management (start/stop)

=head1 VERSION

Version 0.02

=cut

our $VERSION = '0.02';

=head1 SYNOPSIS

    use Sphinx::Manager;

    my $mgr = Sphinx::Manager->new({ config_file => '/etc/sphinx.conf' });
    $mgr->start_searchd;
    $mgr->restart_searchd;
    $mgr->reload_searchd;
    $mgr->stop_searchd;
    $mgr->get_searchd_pid;
    $mgr->run_indexer;

=head1 DESCRIPTION

This module provides utilities to start, stop, restart, and reload the Sphinx
search engine binary (searchd), and to run the Sphinx indexer program.  The
utilities are designed to handle abnormal conditions, such as PID files not
being present when expected, and so should be robust in most situations.

=head1 CONSTRUCTOR

=head2 new

    $mgr = Sphinx::Manager->new(\%opts);

Create a new Sphinx manager.  The names of options are the same as the
setter/getter functions listed below.


=cut

=head1 SETTERS/GETTERS

=head2 config_file

    $mgr->config_file($filename)
    $filename = $mgr->config_file;

Set/get the configuration file.  Defaults to sphinx.conf in current working directory.

=head2 pid_file

    $mgr->pid_file($filename)
    $filename = $mgr->pid_file;

Set/get the PID file.  If given, this will be used in preference to any value in the given config_file.

=head2 bindir

    $mgr->bindir($dir)
    $dir = $mgr->bindir;

Set/get the directory in which to find the Sphinx binaries.

=head2 debug

    $mgr->debug(1);
    $mgr->debug(0);
    $debug_state = $mgr->debug;

Enable/disable debugging messages, or read back debug status.

=head2 process_timeout

    $mgr->process_timeout($secs)
    $secs = $mgr->process_timeout;

Set/get the time (in seconds) to wait for processes to start or stop.

=head2 searchd_args

    $mgr->searchd_args(\@args)
    $args = $mgr->searchd_args;

Set/get the extra command line arguments to pass to searchd when started using
start_searchd.  These should be in the form of an array, each entry comprising
one option or option argument.  Arguments should exclude '--config CONFIG_FILE',
which is included on the command line by default.

=head1 METHODS

=head2 start_searchd

    $mgr->start_searchd;

Starts the Sphinx searchd daemon.  Dies if searchd cannot be started or if it is already running.

=head2 stop_searchd

    $mgr->stop_searchd;

Stops Sphinx searchd daemon.  Dies if searchd cannot be stopped.


=head2 restart_searchd

    $mgr->restart_searchd;

Stops and thens starts the searchd daemon.

=head2 reload_searchd

    $mgr->reload_searchd;

Sends a HUP signal to the searchd daemon if it is running, to tell it to reload
its databases; otherwise starts searchd.

=head2 get_searchd_pid

    $pids = $mgr->get_searchd_pid;

Returns an array ref containing the PID(s) of the searchd daemon.  If the PID
file is in place and searchd is running, then an array containing a single PID
is returned.  If the PID file is not present or is empty, the process table is
checked for other searchd processes running with the specified config file; if
found, all are returned in the array.


=head2 indexer_args

    $mgr->indexer_args(\@args)
    $args = $mgr->indexer_args;

Set/get the extra command line arguments to pass to the indexer program when
started using run_indexer.  These should be in the form of an array, each entry
comprising one option or option argument.  Arguments should exclude '--config
CONFIG_FILE', which is included on the command line by default.

=head2 run_indexer(@args)

Runs the indexer program; dies on error.  Arguments passed to the indexer are
"--config CONFIG_FILE" followed by args set through indexer_args, followed by
any additional args given as parameters to run_indexer.

=head1 CAVEATS

This module has been tested primarily on Linux.  It should work on any other
operating systems where fork() is supported and Proc::ProcessTable works.

=head1 SEE ALSO

L<Sphinx::Search>, L<Sphinx::Config>

=head1 AUTHOR

Jon Schutz, L<http://notes.jschutz.net>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-sphinx-config at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Sphinx-Manager>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Sphinx::Manager

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Sphinx-Manager>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Sphinx-Manager>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Sphinx-Manager>

=item * Search CPAN

L<http://search.cpan.org/dist/Sphinx-Manager>

=back

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

Copyright 2008 Jon Schutz, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1; # End of Sphinx::Manager
