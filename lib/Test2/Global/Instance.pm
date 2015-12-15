package Test2::Global::Instance;
use strict;
use warnings;

use Carp qw/confess/;
use Scalar::Util qw/reftype/;

use Test2::Util qw/get_tid USE_THREADS CAN_FORK pkg_to_file/;

use Test2::Context::Trace();
use Test2::Context::Stack();

use Test2::Util::HashBase qw{
    pid tid
    no_wait
    finalized loaded
    ipc stack format
    contexts

    exit_callbacks
    post_load_callbacks
    context_init_callbacks
    context_release_callbacks
};

# Wrap around the getters that should call _finalize.
for my $finalizer (STACK, IPC, FORMAT) {
    my $orig = __PACKAGE__->can($finalizer);
    my $new = sub {
        my $self = shift;
        $self->_finalize unless $self->{+FINALIZED};
        $self->$orig;
    };

    no strict 'refs';
    no warnings 'redefine';
    *{$finalizer} = $new;
}

sub init { $_[0]->reset }

sub reset {
    my $self = shift;

    $self->{+PID} = $$;
    $self->{+TID} = get_tid();
    $self->{+CONTEXTS} = {};

    $self->{+FINALIZED} = undef;
    $self->{+IPC}       = undef;
    $self->{+STACK}     = undef;
    $self->{+FORMAT}    = undef;

    $self->{+NO_WAIT} = 0;
    $self->{+LOADED}  = 0;

    $self->{+EXIT_CALLBACKS}            = [];
    $self->{+POST_LOAD_CALLBACKS}       = [];
    $self->{+CONTEXT_INIT_CALLBACKS}    = [];
    $self->{+CONTEXT_RELEASE_CALLBACKS} = [];
}

sub _finalize {
    my $self = shift;
    my ($caller) = @_;
    $caller ||= [caller(1)];

    $self->{+FINALIZED} = $caller;
    $self->{+STACK}     = Test2::Context::Stack->new;

    unless ($self->{+FORMAT}) {
        my ($name, $source);
        if ($ENV{TS_FORMATTER}) {
            $name = $ENV{TS_FORMATTER};
            $source = "set by the 'TS_FORMATTER' environment variable";
        }
        else {
            $name = 'TAP';
            $source = 'default formatter';
        }

        my $mod = $name;
        $mod = "Test2::Formatter::$mod"
            unless $mod =~ s/^\+//;

        my $file = pkg_to_file($mod);
        unless (eval { require $file; 1 }) {
            my $err = $@;
            my $line = "* COULD NOT LOAD FORMATTER '$name' ($source) *";
            my $border = '*' x length($line);
            die "\n\n  $border\n  $line\n  $border\n\n$err";
        }

        $self->{+FORMAT} = $mod;
    }

    return unless $INC{'Test2/IPC.pm'};
    $self->{+IPC} = Test2::IPC->init;
}

sub format_set { $_[0]->{+FORMAT} ? 1 : 0 }

sub add_context_init_callback {
    my $self =  shift;
    my ($code) = @_;

    my $rtype = reftype($code) || "";

    confess "Context-init callbacks must be coderefs"
        unless $code && $rtype eq 'CODE';

    # not a big fan of these reftype checks.  maybe:
    #confess "Context-init callbacks must be coderefs"
    #    unless eval { \&$code };

    push @{$self->{+CONTEXT_INIT_CALLBACKS}} => $code;
}

sub add_context_release_callback {
    my $self =  shift;
    my ($code) = @_;

    my $rtype = reftype($code) || "";

    confess "Context-release callbacks must be coderefs"
        unless $code && $rtype eq 'CODE';

    push @{$self->{+CONTEXT_RELEASE_CALLBACKS}} => $code;
}

sub add_post_load_callback {
    my $self = shift;
    my ($code) = @_;

    my $rtype = reftype($code) || "";

    confess "Post-load callbacks must be coderefs"
        unless $code && $rtype eq 'CODE';

    push @{$self->{+POST_LOAD_CALLBACKS}} => $code;
    $code->() if $self->{+LOADED};
}

sub load {
    my $self = shift;
    unless ($self->{+LOADED}) {
        $self->{+LOADED} = 1;
        $_->() for @{$self->{+POST_LOAD_CALLBACKS}};
    }
    return $self->{+LOADED};
}

sub add_exit_callback {
    my $self = shift;
    my ($code) = @_;
    my $rtype = reftype($code) || "";

    confess "End callbacks must be coderefs"
        unless $code && $rtype eq 'CODE';

    push @{$self->{+EXIT_CALLBACKS}} => $code;
}

sub _ipc_wait {
    my $fail = 0;

    while (CAN_FORK) {
        my $pid = CORE::wait();
        my $err = $?;
        last if $pid == -1;
        next unless $err;
        $fail++;
        $err = $err >> 8;
        warn "Process $pid did not exit cleanly (status: $err)\n";
    }

    if (USE_THREADS) {
        for my $t (threads->list()) {
            $t->join;
            # In older threads we cannot check if a thread had an error unless
            # we control it and its return.
            my $err = $t->can('error') ? $t->error : undef;
            next unless $err;
            my $tid = $t->tid();
            $fail++;
            chomp($err);
            warn "Thread $tid did not end cleanly: $err\n";
        }
    }

    return 0 unless $fail;
    return 255;
}

sub set_exit {
    my $self = shift;

    my $exit     = $?;
    my $new_exit = $exit;

    my @unreleased = grep { $_ && $_->trace->pid == $$ } values %{$self->{+CONTEXTS}};
    if (@unreleased) {
        $exit = 255;
        $new_exit = 255;

        $_->trace->alert("context object was never released! This means a testing tool is behaving very badly")
            for @unreleased;
    }

    if ($self->{+PID} != $$ or $self->{+TID} != get_tid()) {
        $? = $exit;
        return;
    }

    my @hubs = $self->{+STACK} ? $self->{+STACK}->all : ();

    if (@hubs and $self->{+IPC} and !$self->{+NO_WAIT}) {
        local $?;
        my %seen;
        for my $hub (reverse @hubs) {
            my $ipc = $hub->ipc or next;
            next if $seen{$ipc}++;
            $ipc->waiting();
        }

        my $ipc_exit = _ipc_wait();
        $new_exit ||= $ipc_exit;
    }

    # None of this is necessary if we never got a root hub
    if(my $root = shift @hubs) {
        my $trace = Test2::Context::Trace->new(
            frame  => [__PACKAGE__, __FILE__, 0, __PACKAGE__ . '::END'],
            detail => __PACKAGE__ . ' END Block finalization',
        );
        my $ctx = Test2::Context->new(
            trace => $trace,
            hub   => $root,
        );

        if (@hubs) {
            $ctx->diag("Test ended with extra hubs on the stack!");
            $new_exit  = 255;
        }

        unless ($root->no_ending) {
            local $?;
            $root->finalize($trace) unless $root->state->ended;
            $_->($ctx, $exit, \$new_exit) for @{$self->{+EXIT_CALLBACKS}};
            $new_exit ||= $root->state->failed;
        }
    }

    $new_exit = 255 if $new_exit > 255;

    $? = $new_exit;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Global::Instance - Object used by Sync under the hood

=head1 EXPERIMENTAL RELEASE

This is an experimental release. Using this right now is not recommended.

=head1 DESCRIPTION

This object encapsulates the global shared state tracked by
L<Test2>. A single global instance of this package is stored (and
obscured) by the L<Test2::Global> package.

There is no reason to directly use this package. This package is documented for
completeness. This package can change, or go away completely at any time.
Directly using, or monkeypatching this package is not supported in any way
shape or form.

=head1 SYNOPSIS

    use Test2::Global::Instance;

    my $obj = Test2::Global::Instance->new;

=over 4

=item $pid = $obj->pid

PID of this instance.

=item $obj->tid

Thread ID of this instance.

=item $obj->reset()

Reset the object to defaults.

=item $bool = $obj->format_set()

Check if a formatter has been set.

=item $obj->load()

Set the internal state to loaded, and run and stored post-load callbacks.

=item $bool = $obj->loaded

Check if the state is set to loaded.

=item $arrayref = $obj->post_load_callbacks

Get the post-load callbacks.

=item $obj->add_post_load_callback(sub { ... })

Add a post-load callback. If C<load()> has already been called then the callback will
be immedietly executed. If C<load()> has not been called then the callback will be
stored and executed later when C<load()> is called.

=item $hashref = $obj->contexts()

Get a hashref of all active contexts keyed by hub id.

=item $arrayref = $obj->context_init_callbacks

Get all context init callbacks.

=item $arrayref = $obj->context_release_callbacks

Get all context release callbacks.

=item $obj->add_context_init_callback(sub { ... })

Add a context init callback. Subs are called every time a context is created. Subs
get the newly created context as their only argument.

=item $obj->add_context_release_callback(sub { ... })

Add a context release callback. Subs are called every time a context is released. Subs
get the released context as their only argument. These callbacks should not
call release on the context.

=item $obj->set_exit()

This is intended to be called in an C<END { ... }> block. This will look at
test state and set $?. This will also call any end callbacks, and wait on child
processes/threads.

=item $bool = $obj->no_wait

=item $bool = $obj->set_no_wait($bool)

Get/Set no_wait. This option is used to turn off process/thread waiting at exit.

=item $arrayref = $obj->exit_callbacks

Get the exit callbacks.

=item $obj->add_exit_callback(sub { ... })

Add an exit callback. This callback will be called by C<set_exit()>.

=item $bool = $obj->finalized

Check if the object is finalized. Finalization happens when either C<ipc()>,
C<stack()>, or C<format()> are called on the object. Once finalization happens
these fields are considered unchangeable (not enforced here, enforced by
L<Test2>).

=item $ipc = $obj->ipc

Get the one true IPC instance.

=item $stack = $obj->stack

Get the one true hub stack.

=item $formatter_class = $obj->format

Get the one true formatter class.

=back

=head1 SOURCE

The source code repository for Test2 can be found at
F<http://github.com/Test-More/Test2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2015 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
