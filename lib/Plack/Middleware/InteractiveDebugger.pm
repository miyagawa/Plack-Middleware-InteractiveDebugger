package Plack::Middleware::InteractiveDebugger;

use strict;
use 5.008_001;
our $VERSION = '0.01';

use parent qw( Plack::Middleware );
use Plack::Util::Accessor qw( resource );

use File::ShareDir;
use Data::Dump::Streamer;
use Devel::StackTrace;
use Devel::StackTrace::WithLexicals;
use Eval::WithLexicals;
use Scalar::Util qw(refaddr);
use Try::Tiny;

use Plack::Middleware::InteractiveDebugger::HTML;
use Plack::App::File;
use Plack::Request;

my $share = try { File::ShareDir::dist_dir('Plack-Middleware-InteractiveDebugger') } || "share";

{
    # Hide from stacktrace's own lexicals
    my %traces;
    sub _traces {
        if (@_ > 1) {
            $traces{$_[0]} = $_[1];
        } else {
            $traces{$_[0]};
        }
    }
}

sub prepare_app {
    my $self = shift;
    $self->resource( Plack::App::File->new(root => $share)->to_app );
}

sub debugger_callback {
    my($self, $env) = @_;

    if ($env->{PATH_INFO} =~ s!/res/!!) {
        return $self->resource->($env);
    } elsif ($env->{PATH_INFO} eq "/source") {
        my $req = Plack::Request->new($env);

        my($trace_id, $idx) = split /-/, $req->query_parameters->{frame};
        my $html = render_source( _traces($trace_id)->frame($idx) );

        return [ 200, [ "Content-Type", "text/html; charset=utf-8" ], [ utf8_safe($html) ] ];
    } elsif ($env->{PATH_INFO} eq "/command") {
        my $req = Plack::Request->new($env);

        my($trace_id, $idx) = split /-/, $req->query_parameters->{frame};
        my $code = $req->query_parameters->{code};

        my $trace = _traces($trace_id);
        my $frame = $trace->frame($idx);

        my $lex = $frame->{__eval} ||= do {
            my $e = Eval::WithLexicals->new;
            $e->in_package("InteractiveDebugger::Pad");
            $e->lexicals($frame->lexicals || {});
            $e;
        };

        local *InteractiveDebugger::Pad::D = sub {
            if (@_) {
                Dump(@_);
            } else {
                Dump($lex->lexicals);
            }
        };

        my @ret = eval { $lex->eval($code) };
        if ($@) {
            @ret = ($@);
        }

        return [ 200, [ 'Content-Type', 'text/html' ], [ "perl&gt; $code\n", map encode_html($_), @ret ] ];
    }
}

sub call {
    my($self, $env) = @_;

    if ($env->{'psgi.multiprocess'}) {
        Carp::croak(__PACKAGE__, " only runs in a single-process mode.");
        return $self->app->($env);
    }

    if ($env->{PATH_INFO} =~ s!^/__debugger__!!) {
        return $self->debugger_callback($env);
    }

    my $trace;
    local $SIG{__DIE__} = sub {
        $trace = Devel::StackTrace::WithLexicals->new(
            indent => 1, message => munge_error($_[0], [ caller ]),
        );
        die @_;
    };

    my $caught;
    my $res = try {
        $self->app->($env);
    } catch {
        $caught = $_;
        [ 500, [ "Content-Type", "text/plain; charset=utf-8" ], [ no_trace_error(utf8_safe($caught)) ] ];
    };

    if ($trace && ($caught || (ref $res eq 'ARRAY' && $res->[0] == 500)) ) {
        $self->filter_frames($trace);
        my $html = render_full($env, $trace);

        $res = [500, ['Content-Type' => 'text/html; charset=utf-8'], [ utf8_safe($html) ]];
        $env->{'psgi.errors'}->print($trace->as_string);

        _traces( refaddr($trace), $trace );
    }

    undef $trace;

    return $res;
}

sub filter_frames {
    my($self, $trace) = @_;

    my @new_frames;
    my @frames = $trace->frames;
    shift @frames if $frames[0]->filename eq __FILE__;

    for my $frame (@frames) {
        push @new_frames, $frame;
        last if $frame->filename eq __FILE__;
    }

    $trace->{frames} = \@new_frames;
}

# below is a copy from StackTrace

sub no_trace_error {
    my $msg = shift;
    chomp($msg);

    return <<EOF;
The application raised the following error:

  $msg

and the middleware couldn't catch its stack trace, possibly because your application overrides \$SIG{__DIE__} by itself, preventing the middleware from working correctly. Remove the offending code or module that does it: known examples are CGI::Carp and Carp::Always.
EOF
}

sub munge_error {
    my($err, $caller) = @_;
    return $err if ref $err;

    # Ugly hack to remove " at ... line ..." automatically appended by perl
    # If there's a proper way to do this, please let me know.
    $err =~ s/ at \Q$caller->[1]\E line $caller->[2]\.\n$//;

    return $err;
}

sub utf8_safe {
    my $str = shift;

    # NOTE: I know messing with utf8:: in the code is WRONG, but
    # because we're running someone else's code that we can't
    # guarnatee which encoding an exception is encoded, there's no
    # better way than doing this. The latest Devel::StackTrace::AsHTML
    # (0.08 or later) encodes high-bit chars as HTML entities, so this
    # path won't be executed.
    if (utf8::is_utf8($str)) {
        utf8::encode($str);
    }

    $str;
}

1;
__END__

=encoding utf-8

=for stopwords

=head1 NAME

Plack::Middleware::InteractiveDebugger - Awesome Interactive Debugger ala Werkzeug

=head1 SYNOPSIS

  enable "InteractiveDebugger";

=head1 WARNINGS

This middleware doesn't work with forking web server implementations
such as L<Starman>.

This middleware exposes an ability to execute any code on the machine
where your application is running, with your own permission. B<Never
enable this middleware on production machines or shared environment>.

=head1 DESCRIPTION

Plack::Middleware::InteractiveDebugger is a PSGI middleware component
that provides an awesome JavaScript in-browser interacive debugger.

=head1 AUTHOR

Tatsuhiko Miyagawa E<lt>miyagawa@bulknews.netE<gt>

=head1 COPYRIGHT

Copyright 2011- Tatsuhiko Miyagawa

Werkzeug HTML, JavaScript, CSS and image files are Copyright 2010 by
the Werkzeug Team. L<http://werkzeug.pocoo.org/>

jQuery is Copyright 2011 John Resig

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

This library contains JavaScript, CSS and image files which are taken
and modified from Werkzeug software, licensed under the BSD license.

This library also contains jQuery library which is licensed under the
MIT license. L<http://jquery.org/license/>

=head1 SEE ALSO

L<http://werkzeug.pocoo.org/> L<Plack::Middleware::StackTrace> L<Plack::Middleware::REPL>

=cut
