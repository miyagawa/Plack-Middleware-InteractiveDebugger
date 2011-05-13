package Plack::Middleware::InteractiveDebugger::HTML;
use strict;
use warnings;

use parent qw(Exporter);
our @EXPORT = qw( render_full render_source encode_html );

use Scalar::Util qw(refaddr);

my $header = <<EOF;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN"
  "http://www.w3.org/TR/html4/loose.dtd">
<html>
  <head>
    <title>%(title) // Plack Interactive Debugger</title>
    <link rel="stylesheet" href="%(script_name)/__debugger__/res/style.css" type="text/css">
    <script type="text/javascript" src="%(script_name)/__debugger__/res/jquery.min.js"></script>
    <script type="text/javascript" src="%(script_name)/__debugger__/res/debugger.js"></script>
    <script type="text/javascript">
      var APP_BASE = '%(script_name)',
          TRACEBACK = %(traceback_id),
          CONSOLE_MODE = %(console),
          EVALEX = %(evalex);
    </script>
  </head>
  <body>
    <div class="debugger">
EOF

my $footer = <<EOF;
      <div class="footer">
        Brought to you by <strong class="arthur">DON'T PANIC</strong>, your
        friendly Plack powered stacktrace interpreter, inspired by Werkzeug.
      </div>
    </div>
  </body>
</html>
EOF

my $page_html = $header . <<EOF . $footer;
<h1>%(exception_type)</h1>
<div class="detail">
  <p class="errormsg">%(exception)</p>
</div>
<h2 class="traceback">StackTrace <em>(most recent call first)</em></h2>
%(summary)
<div class="plain">
    <p>
      This is the Copy/Paste friendly version of the stacktrace.
    </p>
    <textarea cols="50" rows="10" name="code" readonly>%(plaintext)</textarea>
  </form>
</div>
<div class="explanation">
  The debugger caught an exception in your PSGI application.  You can now
  look at the stacktrace which led to the error.  <span class="nojavascript">
  If you enable JavaScript you can also use additional features such as code
  execution and much more.</span>
</div>
EOF

my $console_html = $header . <<EOF . $footer;
<h1>Interactive Console</h1>
<div class="explanation">
In this console you can execute Perl expressions in the context of the
application. 
</div>
<div class="console"><div class="inner">The Console requires JavaScript.</div></div>
EOF

my $summary_html = <<EOF;
<div class="%(classes)">
  StackTrace <em>(most recent call first)</em>
  <ul>%(frames)</ul>
</div>
EOF

my $frame_html = <<EOF;
<div class="frame" id="frame-%(id)">
  <h4>File <cite class="filename">"%(filename)"</cite>,
      line <em class="line">%(lineno)</em>,
      in <code class="function">%(function_name)</code></h4>
  <pre>%(current_line)</pre>
</div>
EOF

my $source_table_html = '<table class=source>%(source)</table>';

my $source_line_html = <<EOF;
<tr class="%(classes)">
  <td class=lineno>%(lineno)</td>
  <td>%(code)</td>
</tr>
EOF

no warnings 'qw';
my %enc = qw( & &amp; > &gt; < &lt; " &quot; ' &#39; );

sub encode_html {
    my $str = shift;
    $str =~ s/([^\x00-\x21\x23-\x25\x28-\x3b\x3d\x3f-\xff])/$enc{$1} || '&#' . ord($1) . ';' /ge;
    utf8::downgrade($str);
    $str;
}

sub render {
    my($html, $vars) = @_;
    $html =~ s/%\((.*?)\)/$vars->{$1}/g;
    $html;
}

sub current_line {
    my $frame = shift;

    open my $fh, "<", $frame->filename or return '';
    my @lines = <$fh>;

    my $line = $lines[$frame->line-1];
    $line =~ s/^\s+//;
    $line;
}

sub render_frame {
    my($trace, $idx) = @_;

    my $frame = $trace->frame($idx);

    render $frame_html, {
        id            => refaddr($trace) . "-" . $idx,
        filename      => encode_html($frame->filename),
        lineno        => $frame->line,
        function_name => $frame->subroutine ? encode_html($frame->subroutine) : '',
        current_line  => current_line($frame),
    };
}

sub render_line {
    my($frame, $line, $lineno) = @_;

    my @classes = ('line');
    push @classes, 'current' if $frame->line == $lineno;

    render $source_line_html, {
        classes => join(" ", @classes),
        lineno  => $lineno,
        code    => encode_html($line),
    };
}

sub render_source {
    my $frame = shift;

    my $source;

    open my $fh, "<", $frame->filename or return '';
    my @lines = <$fh>;

    my $lineno = 1;
    for my $line (@lines) {
        $source .= render_line $frame, $line, $lineno++;
        $source .= "\n";
    }

    render $source_table_html, { source => $source };
}

sub render_summary {
    my $trace = shift;

    my @classes = ('traceback');
    unless ($trace->frames) {
        push @classes, 'noframe-traceback';
    }

    my $out;
    for my $idx (0..$trace->frame_count-1) {
        $out .= '<li>' . render_frame($trace, $idx);
    }

    render $summary_html, {
        classes => join(" ", @classes),
        frames  => $out,
    };
}

sub render_full {
    my($env, $trace) = @_;
    my $msg = encode_html($trace->frame(0)->as_string(1));
    render $page_html, {
        script_name => $env->{SCRIPT_NAME},
        evalex      => 'true',
        console     => 'false',
        title       => $msg,
        exception   => $msg,
        exception_type => ref(($trace->frame(0)->args)[0]) || "Error",
        summary     => render_summary($trace),
        plaintext   => $trace->as_string,
        traceback_id => refaddr($trace),
    };
}

1;
