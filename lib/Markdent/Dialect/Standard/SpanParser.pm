package Markdent::Dialect::Standard::SpanParser;

use strict;
use warnings;

our $VERSION = '0.02';

use re 'eval';

use List::AllUtils qw( uniq );
use Markdent::Event::AutoLink;
use Markdent::Event::EndCode;
use Markdent::Event::EndEmphasis;
use Markdent::Event::EndHTMLTag;
use Markdent::Event::EndLink;
use Markdent::Event::EndStrong;
use Markdent::Event::HTMLComment;
use Markdent::Event::HTMLEntity;
use Markdent::Event::HTMLTag;
use Markdent::Event::Image;
use Markdent::Event::StartCode;
use Markdent::Event::StartEmphasis;
use Markdent::Event::StartHTMLTag;
use Markdent::Event::StartLink;
use Markdent::Event::StartStrong;
use Markdent::Event::Text;
use Markdent::Regexes qw( $HTMLComment );
use Markdent::Types qw( Str ArrayRef HashRef RegexpRef EventObject );

use namespace::autoclean;
use Moose;
use MooseX::SemiAffordanceAccessor;
use MooseX::StrictConstructor;

with 'Markdent::Role::SpanParser';

has __pending_events => (
    traits   => ['Array'],
    is       => 'rw',
    isa      => ArrayRef[EventObject],
    default  => sub { [] },
    init_arg => undef,
    handles  => {
        _pending_events       => 'elements',
        _add_pending_event    => 'push',
        _clear_pending_events => 'clear',
    },
);

has _span_text_buffer => (
    traits   => ['String'],
    is       => 'ro',
    isa      => Str,
    default  => q{},
    init_arg => undef,
    handles  => {
        _save_span_text         => 'append',
        _has_span_text_buffer   => 'length',
        _clear_span_text_buffer => 'clear',
    },
);

has _links_by_id => (
    traits   => ['Hash'],
    is       => 'ro',
    isa      => HashRef[ArrayRef],
    default  => sub { {} },
    init_arg => undef,
    handles  => {
        _add_link_by_id => 'set',
        _get_link_by_id => 'get',
    },
);

has _escape_re => (
    is       => 'ro',
    isa      => RegexpRef,
    lazy     => 1,
    builder  => '_build_escape_re',
    init_arg => undef,
);

has _escapable_chars => (
    is      => 'ro',
    isa     => ArrayRef [Str],
    lazy    => 1,
    builder => '_build_escapable_chars',
);

sub extract_link_ids {
    my $self = shift;
    my $text = shift;

    ${$text} =~ s/ ^
                   \p{SpaceSeparator}{0,3}
                   \[ ([^]]+) \]
                   :
                   \p{SpaceSeparator}*
                   \n?
                   \p{SpaceSeparator}*
                   (.+)
                   \n
                 /
                   $self->_process_id_for_link( $1, $2 );
                 /egxm;
}

sub _process_id_for_link {
    my $self    = shift;
    my $id      = shift;
    my $id_text = shift;

    $id_text =~ s/\s+$//;

    my ( $uri, $title ) = $self->_parse_uri_and_title($id_text);

    $self->_add_link_by_id( $id => [ $uri, $title ] );

    return q{};
}

sub _parse_uri_and_title {
    my $self = shift;
    my $text = shift;

    $text =~ s/^\s+|\s+$//g;

    my ( $uri, $title ) = split /(?:\p{SpaceSeparator}|\t)+/, $text, 2;

    $uri = q{}
        unless defined $uri;

    $uri =~ s/^<|>$//g;
    $title =~ s/^"|"$//g
        if defined $title;

    return ( $uri, $title );
}

sub parse_block {
    my $self = shift;
    my $text = shift;

    $self->_print_debug( "Parsing text for span-level markup\n\n$text\n" )
        if $self->debug();

    # Note that we have to pass a _reference_ to text in order to make sure
    # that we are matching the same variable with /g regexes each time.
    $self->_parse_text(\$text);

    # This catches any bad start events that were found after the last end
    # event, or if there were _no_ end events at all.
    $self->_convert_invalid_start_events_to_text('is done');

    $self->_debug_pending_events('before text merging');

    $self->_merge_consecutive_text_events();

    $self->_debug_pending_events('after text merging');

    $self->handler()->handle_event($_)
        for $self->_pending_events();

    $self->_clear_pending_events();

    return;
}

sub _parse_text {
    my $self = shift;
    my $text = shift;

 PARSE:
    while (1) {
        if ( $self->debug() && pos ${$text} ) {
            $self->_print_debug( "Remaining text:\n[\n"
                    . substr( ${$text}, pos ${$text} )
                    . "\n]\n" );
        }

        if ( ${$text} =~ /\G\z/gc ) {
            $self->_event_for_text_buffer();
            last;
        }

        my @look_for = $self->_possible_span_matches();

        $self->_debug_look_for(@look_for);

        for my $span (@look_for) {
            my ( $markup, @args ) = ref $span ? @{$span} : $span;

            my $meth = '_match_' . $markup;

            $self->$meth( $text, @args )
                and next PARSE;
        }

        $self->_match_plain_text($text);
    }
}

sub _possible_span_matches {
    my $self = shift;

    if ( my $event = $self->_open_start_event_for_span('code') ) {
        return [ 'code_end', $event->delimiter() ];
    }

    my @look_for = 'escape';

    push @look_for, $self->_look_for_strong_and_emphasis();

    push @look_for, 'code_start';

    unless ( $self->_open_start_event_for_span('link') ) {
        push @look_for, qw( auto_link link image );
    }

    push @look_for, 'html_comment', 'html_tag', 'html_entity';

    return @look_for;
}

sub _look_for_strong_and_emphasis {
    my $self = shift;

    my %start;
    $start{strong}   = $self->_open_start_event_for_span('strong');
    $start{emphasis} = $self->_open_start_event_for_span('emphasis');

    # If we are in both, we need to try to end the most recent one first.
    if ( $start{strong} && $start{emphasis} ) {
        my $last_saw;
        for my $event ( $self->_pending_events() ) {
            if ( $event->event_name() eq 'start_strong' ) {
                $last_saw = 'strong';
            }
            elsif ( $event->event_name() eq 'start_emphasis' ) {
                $last_saw = 'emphasis';
            }
        }

        my @order
            = $last_saw eq 'strong'
            ? qw( strong emphasis )
            : qw( emphasis strong );

        return
            map { [ $_ . '_end', $start{$_}->delimiter() ] }
            @order;
    }
    elsif ( $start{emphasis} ) {
        return ( 'strong_start',
            [ 'emphasis_end', $start{emphasis}->delimiter() ] );
    }
    elsif ( $start{strong} ) {
        return (
            [ 'strong_end', $start{strong}->delimiter() ],
            'emphasis_start'
        );
    }

    # We look for strong first since it's a longer version of emphasis (we
    # need to try to match ** before *).
    return ( 'strong_start', 'emphasis_start' );
}

sub _open_start_event_for_span {
    my $self = shift;
    my $type = shift;

    my $in;
    for my $event ( $self->_pending_events() ) {
        $in = $event
            if $event->event_name eq 'start_' . $type;

        undef $in
            if $event->event_name eq 'end_' . $type;
    }

    return $in;
}

sub _build_escapable_chars {
    return [ qw( \ ` * _ { } [ \ ] ( ) + \ - . ! < > ), '#' ];
}

sub _build_escape_re {
    my $self = shift;

    my $chars = join q{}, uniq( @{ $self->_escapable_chars() } );

    return qr/\\([\Q$chars\E])/;
}

sub _match_escape {
    my $self = shift;
    my $text = shift;

    my $escape_re = $self->_escape_re();

    return unless ${$text} =~ / \G
                                ($escape_re)
                              /xgc;

    $self->_print_debug( "Interpreting as escaped character\n\n[$1]\n" )
        if $self->debug();

    $self->_save_span_text($2);

    return 1;
}

sub _match_strong_start {
    my $self = shift;
    my $text = shift;

    my ($delim) = $self->_match_delimiter_start( $text, qr/(?:\*\*|__)/ )
        or return;

    my $event = $self->_make_event( StartStrong => delimiter => $delim );

    $self->_markup_event($event);

    return 1;
}

sub _match_strong_end {
    my $self  = shift;
    my $text  = shift;
    my $delim = shift;

    $self->_match_delimiter_end( $text, qr/\Q$delim\E/ )
        or return;

    my $event = $self->_make_event( EndStrong => delimiter => $delim );

    $self->_markup_event($event);

    return 1;
}

sub _match_emphasis_start {
    my $self = shift;
    my $text = shift;

    my ($delim) = $self->_match_delimiter_start( $text, qr/(?:\*|_)/ )
        or return;

    my $event = $self->_make_event( StartEmphasis => delimiter => $delim );

    $self->_markup_event($event);

    return 1;
}

sub _match_emphasis_end {
    my $self  = shift;
    my $text  = shift;
    my $delim = shift;

    $self->_match_delimiter_end( $text, qr/\Q$delim\E/ )
        or return;

    my $event = $self->_make_event( EndEmphasis => delimiter => $delim );

    $self->_markup_event($event);

    return 1;
}

sub _match_code_start {
    my $self = shift;
    my $text = shift;

    my ($delim) = $self->_match_delimiter_start( $text, qr/\`+\p{SpaceSeparator}*/ )
        or return;

    $delim =~ s/\p{SpaceSeparator}*$//;

    my $event = $self->_make_event( StartCode => delimiter => $delim );

    $self->_markup_event($event);

    return 1;
}

sub _match_code_end {
    my $self  = shift;
    my $text  = shift;
    my $delim = shift;

    $self->_match_delimiter_end( $text, qr/\p{SpaceSeparator}*\Q$delim/ )
        or return;

    my $event = $self->_make_event( EndCode => delimiter => $delim );

    $self->_markup_event($event);

    return 1;
}

sub _match_delimiter_start {
    my $self  = shift;
    my $text  = shift;
    my $delim = shift;

    return unless ${$text} =~ / \G ($delim)/xgc;

    return $1;
}

sub _match_delimiter_end {
    my $self        = shift;
    my $text        = shift;
    my $delim       = shift;

    return unless ${$text} =~ /\G $delim /xgc;

    return 1;
}

sub _match_auto_link {
    my $self = shift;
    my $text = shift;

    return unless ${$text} =~ /\G <( (?:https?|mailto|ftp): [^>]+ ) >/xgc;

    my $link = $self->_make_event( AutoLink => uri => $1 );

    $self->_markup_event($link);

    return 1;
}

# Stolen from Text::Markdown
my $nested_brackets;
$nested_brackets = qr{
    (?>                                 # Atomic matching
       [^\[\]]+                         # Anything other than brackets
       |
       \[
         (??{ $nested_brackets })       # Recursive set of nested brackets
       \]
    )*
}x;

# Also stolen from Text::Markdown
my $nested_parens;
$nested_parens = qr{
    (?>                                 # Atomic matching
       [^()]+                           # Anything other than parens
       |
       \(
         (??{ $nested_parens })         # Recursive set of nested parens
       \)
    )*
}x;

sub _match_link {
    my $self = shift;
    my $text = shift;

    my $pos = pos ${$text} || 0;

    # For some inexplicable reason, this regex needs to be recreated each time
    # the method is called or $nested_brackets && $nested_parens are
    # undef. Presumably this has something to do with using it in a
    # subroutine's lexical scope (resetting the stack on each invocation?)
    return unless
        ${$text} =~ / \G
                      \[ ($nested_brackets) \]    # link or alt text
                      (?:
                        \( ($nested_parens) \)
                        |
                        \s*
                        \[ ( [^]]* ) \]           # an id (can be empty)
                      )?                          # with no id or explicit uri, use text as id
                    /xgc;

    my ( $link_text, $attr ) =
        $self->_link_match_results( $1, $2, $3 );

    unless ( defined $attr->{uri} ) {
        pos ${$text} = $pos
            if defined $pos;

        return;
    }

    my $start = $self->_make_event( StartLink => %{$attr} );

    $self->_markup_event($start);

    $self->_parse_text( \$link_text );

    my $end = $self->_make_event('EndLink');

    $self->_markup_event($end);

    return 1;
}

sub _match_image {
    my $self = shift;
    my $text = shift;

    my $pos = pos ${$text} || 0;

    return unless
        ${$text} =~ / \G
                      !
                      \[ ($nested_brackets) \]    # link or alt text
                      (?:
                        \( ($nested_parens) \)
                        |
                        \s*
                        \[ ( [^]]* ) \]           # an id (can be empty)
                      )?                          # with no id or explicit uri, use text as id
                    /xgc;

    my ( $alt_text, $attr ) =
        $self->_link_match_results( $1, $2, $3 );

    unless ( defined $attr->{uri} ) {
        pos ${$text} = $pos
            if defined $pos;

        return;
    }

    $attr->{alt_text} = $alt_text;

    my $image = $self->_make_event( Image => %{$attr} );

    $self->_markup_event($image);

    return 1;
}

sub _link_match_results {
    my $self          = shift;
    my $text          = shift;
    my $uri_and_title = shift;
    my $id            = shift;

    my %attr;
    if ( defined $uri_and_title ) {
        my ( $uri, $title ) = $self->_parse_uri_and_title($uri_and_title);

        $attr{uri}   = $uri;
        $attr{title} = $title
            if defined $title;
    }
    else {
        unless ( defined $id && length $id ) {
            $id = $text;
            $attr{is_implicit_id} = 1;
        }

        $id =~ s/\s+/ /g;

        my $link = $self->_get_link_by_id($id) || [];

        $attr{uri}   = $link->[0];
        $attr{title} = $link->[1]
            if defined $link->[1];
        $attr{id} = $id;
    }

    return ( $text, \%attr );
}

sub _match_html_comment {
    my $self = shift;
    my $text = shift;

    return unless ${$text} =~ / \G
                                $HTMLComment
                              /xgcs;

    my $event = $self->_make_event( HTMLComment => text => $1 );

    $self->_markup_event($event);
}

my %InlineTags = map { $_ => 1 }
    qw( area base basefont br col frame hr img input link meta param );

sub _match_html_tag {
    my $self = shift;
    my $text = shift;

    return unless ${$text} =~ /\G (< [^>]+ >)/xgc;

    my $tag = $1;

    my $event;
    if ( $tag =~ m{^</(\w+)>$} ) {
        $event = $self->_make_event( EndHTMLTag => tag => $1 );
    }
    else {
        $tag =~ s/^<|>$//g;

        my ( $name, $attr ) = split /\s+/, $tag, 2;

        $attr =~ s{/\s*$}{}
            if defined $attr;

        my %attr;
        if ( defined $attr && $attr =~ /\S/ ) {
            for my $attr ( split /\s+/, $attr ) {
                if ( $attr =~ /=/ ) {
                    my ( $name, $val ) = split /=/, $attr;

                    $val =~ s/^([\"\'])(.+)\1$/$2/g;

                    $attr{$name} = $val;
                }
                else {
                    # A value-less attribute like in
                    # <option value="1" selected>
                    $attr{$name} = undef;
                }
            }
        }

        if ( $InlineTags{$name} ) {
            $event = $self->_make_event(
                HTMLTag => (
                    tag        => $name,
                    attributes => \%attr,
                ),
            );
        }
        else {
            $event = $self->_make_event(
                StartHTMLTag => (
                    tag        => $name,
                    attributes => \%attr,
                ),
            );
        }
    }

    $self->_markup_event($event);

    return 1;
}

sub _match_html_entity {
    my $self = shift;
    my $text = shift;

    return unless ${$text} =~ / \G
                                &(\S+);
                              /xgcs;

    my $event = $self->_make_event( HTMLEntity => entity => $1 );

    $self->_markup_event($event);
}

sub _match_plain_text {
    my $self = shift;
    my $text = shift;

    my $escape_re = $self->_escape_re();

    # Note that we're careful not to consume any of the characters marking the
    # (possible) end of the plain text. If those things turn out to _not_ be
    # markup, we'll get them on the next pass, because we always match at
    # least one character, so we should never get stuck in a loop.
    return unless
        ${$text} =~ /\G
                     ( .+? )              # at least one character followed by ...
                     (?=
                       $escape_re
                       |
                       \*                 #   possible span markup
                       |
                       _
                       |
                       \p{SpaceSeparator}* \`
                       |
                       !?\[               #   possible image or link
                       |
                       < [^>]+ >          #   an HTML tag
                       |
                       &\S+;              #   an HTML entity
                       |
                       \z                 #   or the end of the string
                     )
                    /xgcs;

    $self->_print_debug( "Interpreting as plain text\n\n[$1]\n" )
        if $self->debug();

    $self->_save_span_text($1);

    return 1;
}

sub _markup_event {
    my $self = shift;
    my $event = shift;

    $self->_event_for_text_buffer();

    if ( $self->debug() ) {
        my $msg = 'Found markup: ' . $event->event_name();

        if ( $event->can('delimiter') ) {
            $msg .= ' - delimiter: [' . $event->delimiter() . ']';
        }

        $msg .= "\n";

        $self->_print_debug($msg);
    }

    $self->_add_pending_event($event);

    $self->_convert_invalid_start_events_to_text()
        if $event->is_end();
}

sub _event_for_text_buffer {
    my $self = shift;

    return unless $self->_has_span_text_buffer();

    my $text = $self->_span_text_buffer();

    $self->_detab_text(\$text);

    my $event = $self->_make_event( Text => text => $text );

    $self->_add_pending_event($event);

    $self->_clear_span_text_buffer();
}

sub _convert_invalid_start_events_to_text {
    my $self    = shift;
    my $is_done = shift;

    # We want to operate directly on the reference so we can convert
    # individual events in place
    my $events = $self->__pending_events();

    my @starts;
EVENT:
    for my $i ( 0 .. $#{$events} ) {
        my $event = $events->[$i];

        if ( $event->is_start() ) {
            push @starts, [ $i, $event ];
        }
        elsif ( $event->is_end() ) {
            while ( my $start = pop @starts ) {
                next EVENT
                    if $event->balances_event( $start->[1] );

                $events->[ $start->[0] ]
                    = $self->_convert_start_event_to_text( $start->[1] );
            }
        }
    }

    return unless $is_done;

    for my $start (@starts) {
        $events->[ $start->[0] ] = $self->_convert_start_event_to_text( $start->[1] );
    }
}

sub _convert_start_event_to_text {
    my $self  = shift;
    my $event = shift;

    $self->_print_debug( 'Found bad start event for '
            . $event->name()
            . q{ with "}
            . $event->delimiter()
            . q{" as the delimiter}
            . "\n" )
        if $self->debug();

    return $self->_make_event(
        Text => (
            text            => $event->as_text(),
            _converted_from => $event->event_name(),
        )
    );
}

sub _merge_consecutive_text_events {
    my $self = shift;

    my $events = $self->__pending_events();

    my $merge_start;

    my @to_merge;
    for my $i ( 0 .. $#{$events} ) {
        my $event = $events->[$i];

        if ( $event->event_name() eq 'text' ) {
            $merge_start = $i
                unless defined $merge_start;
        }
        else {
            push @to_merge, [ $merge_start, $i - 1 ]
                if defined $merge_start && $i - 1 > $merge_start;

            undef $merge_start;
        }
    }

    # If $merge_start is still defined, then the last event was a text event
    # which may need to be merged.
    push @to_merge, [ $merge_start, $#{$events} ]
        if defined $merge_start && $#{$events} > $merge_start;

    my $already_merged = 0;
    for my $pair (@to_merge) {
        $pair->[0] -= $already_merged;
        $pair->[1] -= $already_merged;

        $self->_splice_merged_text_event(
            $events,
            @{$pair},
        );

        $already_merged += $pair->[1] - $pair->[0];
    }
}

sub _splice_merged_text_event {
    my $self     = shift;
    my $events   = shift;
    my $start    = shift;
    my $end      = shift;

    my @to_merge = map { $_->text() } @{$events}[ $start .. $end ];

    $self->_print_debug( "Merging consecutive text events ($start-$end) for: \n"
            . ( join q{}, map {"  - [$_]\n"} @to_merge ) )
        if $self->debug();

    my $merged_text = join q{}, @to_merge;

    my $event = $self->_make_event(
        Text => (
            text         => $merged_text,
            _merged_from => \@to_merge,
        ),
    );

    splice @{$events}, $start, ( $end - $start ) + 1, $event;
}

sub _debug_pending_events {
    my $self = shift;
    my $desc = shift;

    return unless $self->debug();

    my $msg = "Pending event stream $desc:\n";

    for my $event ( $self->_pending_events() ) {
        $msg .= $event->debug_dump() . "\n";
    }

    $self->_print_debug($msg);
}

__PACKAGE__->meta()->make_immutable();

1;

__END__

=pod

=head1 NAME

Markdent::Dialect::Standard::SpanParser - Span parser for standard Markdown

=head1 DESCRIPTION

This class parses spans for the standard Markdown dialect (as defined by
Daring Fireball and mdtest).

=head1 METHODS

This class provides the following methods:

=head2 Markdent::Dialect::Standard::SpanParser->new( handler => $handler )

Creates a new span parser object. You must provide a span parser object.

=head2 $span_parser->extract_link_ids(\$markdown)

This method takes a reference to a markdown string and parses it for link
ids. These are removed from the document and stored in the span parser for
later use.

=head2 $span_parser->parse_block(\$block)

Parses a block for span-level markup.

=head1 ROLES

This class does the L<Markdent::Role::SpanParser>,
L<Markdent::Role::AnyParser>, and L<Markdent::Role::DebugPrinter> roles.

=head1 BUGS

See L<Markdent> for bug reporting details.

=head1 AUTHOR

Dave Rolsky, E<lt>autarch@urth.orgE<gt>

=head1 COPYRIGHT & LICENSE

Copyright 2009 Dave Rolsky, All Rights Reserved.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
