package Perinci::Sub::Complete;

our $DATE = '2014-07-29'; # DATE
our $VERSION = '0.60'; # VERSION

use 5.010001;
use strict;
use warnings;
use experimental 'smartmatch';
use Log::Any '$log';

use Complete::Util qw(complete_array_elem);
use Perinci::Sub::Util qw(gen_modified_sub);

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(
                       complete_from_schema
                       complete_arg_val
                       complete_arg_elem
                       complete_cli_arg
               );
our %SPEC;

my %common_args_riap = (
    riap_client => {
        summary => 'Optional, to perform complete_arg_val to the server',
        schema  => 'obj*',
        description => <<'_',

When the argument spec in the Rinci metadata contains `completion` key, this
means there is custom completion code for that argument. However, if retrieved
from a remote server, sometimes the `completion` key no longer contains the code
(it has been cleansed into a string). Moreover, the completion code needs to run
on the server.

If supplied this argument and te `riap_server_url` argument, the function will
try to request to the server (via Riap request `complete_arg_val`). Otherwise,
the function will just give up/decline completing.

_
        },
    riap_server_url => {
        summary => 'Optional, to perform complete_arg_val to the server',
        schema  => 'str*',
        description => <<'_',

See the `riap_client` argument.

_
    },
    riap_uri => {
        summary => 'Optional, to perform complete_arg_val to the server',
        schema  => 'str*',
        description => <<'_',

See the `riap_client` argument.

_
    },
);

$SPEC{complete_from_schema} = {
    v => 1.1,
    summary => 'Complete a value from schema',
    description => <<'_',

Employ some heuristics to complete a value from Sah schema. For example, if
schema is `[str => in => [qw/new open resolved rejected/]]`, then we can
complete from the `in` clause. Or for something like `[int => between => [1,
20]]` we can complete using values from 1 to 20.

_
    args => {
        schema => {
            summary => 'Must be normalized',
            req => 1,
        },
        word => {
            schema => [str => default => ''],
            req => 1,
        },
        ci => {
            schema => 'bool',
        },
    },
};
sub complete_from_schema {
    my %args = @_;
    my $sch  = $args{schema}; # must be normalized
    my $word = $args{word} // "";
    my $ci   = $args{ci};

    my ($type, $cs) = @{$sch};

    my $words;
    eval {
        if ($cs->{is} && !ref($cs->{is})) {
            $log->tracef("adding completion from 'is' clause");
            push @$words, $cs->{is};
            return; # from eval. there should not be any other value
        }
        if ($cs->{in}) {
            $log->tracef("adding completion from 'in' clause");
            push @$words, grep {!ref($_)} @{ $cs->{in} };
            return; # from eval. there should not be any other value
        }
        if ($type =~ /\Abool\*?\z/) {
            $log->tracef("adding completion from possible values of bool");
            push @$words, 0, 1;
            return; # from eval
        }
        if ($type =~ /\Aint\*?\z/) {
            my $limit = 100;
            if ($cs->{between} &&
                    $cs->{between}[0] - $cs->{between}[0] <= $limit) {
                $log->tracef("adding completion from 'between' clause");
                push @$words, $cs->{between}[0] .. $cs->{between}[1];
            } elsif ($cs->{xbetween} &&
                         $cs->{xbetween}[0] - $cs->{xbetween}[0] <= $limit) {
                $log->tracef("adding completion from 'xbetween' clause");
                push @$words, $cs->{xbetween}[0]+1 .. $cs->{xbetween}[1]-1;
            } elsif (defined($cs->{min}) && defined($cs->{max}) &&
                         $cs->{max}-$cs->{min} <= $limit) {
                $log->tracef("adding completion from 'min' & 'max' clauses");
                push @$words, $cs->{min} .. $cs->{max};
            } elsif (defined($cs->{min}) && defined($cs->{xmax}) &&
                         $cs->{xmax}-$cs->{min} <= $limit) {
                $log->tracef("adding completion from 'min' & 'xmax' clauses");
                push @$words, $cs->{min} .. $cs->{xmax}-1;
            } elsif (defined($cs->{xmin}) && defined($cs->{max}) &&
                         $cs->{max}-$cs->{xmin} <= $limit) {
                $log->tracef("adding completion from 'xmin' & 'max' clauses");
                push @$words, $cs->{xmin}+1 .. $cs->{max};
            } elsif (defined($cs->{xmin}) && defined($cs->{xmax}) &&
                         $cs->{xmax}-$cs->{xmin} <= $limit) {
                $log->tracef("adding completion from 'xmin' & 'xmax' clauses");
                push @$words, $cs->{xmin}+1 .. $cs->{xmax}-1;
            } elsif (length($word) && $word !~ /\A-?\d*\z/) {
                $log->tracef("word not an int");
                $words = [];
            } else {
                # do a digit by digit completion
                $words = [];
                for my $sign ("", "-") {
                    for ("", 0..9) {
                        my $i = $sign . $word . $_;
                        next unless length $i;
                        next unless $i =~ /\A-?\d+\z/;
                        next if $i eq '-0';
                        next if $i =~ /\A-?0\d/;
                        next if $cs->{between} &&
                            ($i < $cs->{between}[0] ||
                                 $i > $cs->{between}[1]);
                        next if $cs->{xbetween} &&
                            ($i <= $cs->{xbetween}[0] ||
                                 $i >= $cs->{xbetween}[1]);
                        next if defined($cs->{min} ) && $i <  $cs->{min};
                        next if defined($cs->{xmin}) && $i <= $cs->{xmin};
                        next if defined($cs->{max} ) && $i >  $cs->{max};
                        next if defined($cs->{xmin}) && $i >= $cs->{xmax};
                        push @$words, $i;
                    }
                }
                $words = [sort @$words];
            }
            return; # from eval
        }
        if ($type =~ /\Afloat\*?\z/) {
            if (length($word) && $word !~ /\A-?\d*(\.\d*)?\z/) {
                $log->tracef("word not a float");
                $words = [];
            } else {
                $words = [];
                for my $sig ("", "-") {
                    for ("", 0..9,
                         ".0",".1",".2",".3",".4",".5",".6",".7",".8",".9") {
                        my $f = $sig . $word . $_;
                        next unless length $f;
                        next unless $f =~ /\A-?\d+(\.\d+)?\z/;
                        next if $f eq '-0';
                        next if $f =~ /\A-?0\d\z/;
                        next if $cs->{between} &&
                            ($f < $cs->{between}[0] ||
                                 $f > $cs->{between}[1]);
                        next if $cs->{xbetween} &&
                            ($f <= $cs->{xbetween}[0] ||
                                 $f >= $cs->{xbetween}[1]);
                        next if defined($cs->{min} ) && $f <  $cs->{min};
                        next if defined($cs->{xmin}) && $f <= $cs->{xmin};
                        next if defined($cs->{max} ) && $f >  $cs->{max};
                        next if defined($cs->{xmin}) && $f >= $cs->{xmax};
                        push @$words, $f;
                    }
                }
            }
            return; # from eval
        }
    }; # eval

    return undef unless $words;
    complete_array_elem(array=>$words, word=>$word, ci=>$ci);
}

$SPEC{complete_arg_val} = {
    v => 1.1,
    summary => 'Given argument name and function metadata, complete value',
    description => <<'_',

Will attempt to complete using the completion routine specified in the argument
specification, or if that is not specified, from argument's schema using
`complete_from_schema`.

_
    args => {
        meta => {
            summary => 'Rinci function metadata, must be normalized',
            schema => 'hash*',
            req => 1,
        },
        arg => {
            summary => 'Argument name',
            schema => 'str*',
            req => 1,
        },
        word => {
            summary => 'Word to be completed',
            schema => ['str*', default => ''],
        },
        ci => {
            summary => 'Whether to be case-insensitive',
            schema => ['bool*', default => 0],
        },
        args => {
            summary => 'Collected arguments so far, '.
                'will be passed to completion routines',
            schema  => 'hash',
        },
        extras => {
            summary => 'To pass extra arguments to completion routines',
            schema  => 'hash',
        },

        %common_args_riap,
    },
    result_naked => 1,
    result => {
        schema => 'array', # XXX of => str*
    },
};
sub complete_arg_val {
    my %args = @_;

    my $meta = $args{meta} or do {
        $log->tracef("meta is not supplied, declining");
        return undef;
    };
    my $arg  = $args{arg} or do {
        $log->tracef("arg is not supplied, declining");
        return undef;
    };
    $log->tracef("completing argument value for arg %s", $arg);
    my $ci   = $args{ci} // 0;
    my $word = $args{word} // '';

    # XXX reject if meta's v is not 1.1

    my $args_p = $meta->{args} // {};
    my $arg_p = $args_p->{$arg} or do {
        $log->tracef("arg '$arg' is not specified in meta, declining");
        return undef;
    };

    my $reply;
    eval { # completion sub can die, etc.

        my $comp = $arg_p->{completion};
        if ($comp) {
            $log->tracef("calling arg spec's completion");
            if (ref($comp) eq 'CODE') {
                $reply = $comp->(
                    word=>$word, ci=>$ci, args=>$args{args},
                    extras=>$args{extras});
                return; # from eval
            } elsif (ref($comp) eq 'ARRAY') {
                $reply = complete_array_elem(
                    array=>$comp, word=>$word, ci=>$ci);
                return; # from eval
            }

            $log->tracef("arg spec's completion is not a coderef or arrayref");
            if ($args{riap_client} && $args{riap_server_url}) {
                $log->tracef("trying to request complete_arg_val to server");
                my $res = $args{riap_client}->request(
                    complete_arg_val => $args{riap_server_url},
                    {(uri=>$args{riap_uri}) x !!defined($args{riap_uri}),
                     arg=>$arg, word=>$word, ci=>$ci},
                );
                if ($res->[0] != 200) {
                    $log->tracef("request failed (%s), declining", $res);
                    return; # from eval
                }
                $reply = $res->[2];
                return; # from eval
            }

            $log->tracef("declining");
            return; # from eval
        }

        my $sch = $arg_p->{schema};
        unless ($sch) {
            $log->tracef("arg spec does not specify schema, declining");
            return; # from eval
        };

        # XXX normalize schema if not normalized

        $log->tracef("completing using schema");
        $reply = complete_from_schema(schema=>$sch, word=>$word, ci=>$ci);
    };
    $log->debug("Completion died: $@") if $@;
    unless ($reply) {
        $log->tracef("no completion from metadata possible, declining");
        return undef;
    }

    $reply;
}

gen_modified_sub(
    output_name  => 'complete_arg_elem',
    install_sub  => 0,
    base_name    => 'complete_arg_val',
    summary      => 'Given argument name and function metadata, '.
        'complete array element',
    add_args     => {
        index => {
            summary => 'Index of element to complete',
            schema  => [int => min => 0],
        },
    },
);
sub complete_arg_elem {
    require Data::Sah::Normalize;

    my %args = @_;

    my $meta = $args{meta} or do {
        $log->tracef("meta is not supplied, declining");
        return undef;
    };
    my $arg  = $args{arg} or do {
        $log->tracef("arg is not supplied, declining");
        return undef;
    };
    defined(my $index = $args{index}) or do {
        $log->tracef("index is not supplied, declining");
        return undef;
    };
    $log->tracef("completing argument element %s[%d]", $arg, $index);
    my $ci   = $args{ci} // 0;
    my $word = $args{word} // '';

    # XXX reject if meta's v is not 1.1

    my $args_p = $meta->{args} // {};
    my $arg_p = $args_p->{$arg} or do {
        $log->tracef("arg '$arg' is not specified in meta, declining");
        return undef;
    };

    my $reply;
    eval { # completion sub can die, etc.

        my $elcomp = $arg_p->{element_completion};
        if ($elcomp) {
            $log->tracef("calling arg spec's element_completion [$index]");
            if (ref($elcomp) eq 'CODE') {
                $reply = $elcomp->(
                    word=>$word, ci=>$ci, index=>$index,
                    args=>$args{args}, extras=>$args{extras});
                return; # from eval
            } elsif (ref($elcomp) eq 'ARRAY') {
                $reply = complete_array_elem(
                    array=>$elcomp, word=>$word, ci=>$ci);
            }

            $log->tracef("arg spec's element_completion is not a coderef or ".
                             "arrayref");
            if ($args{riap_client} && $args{riap_server_url}) {
                $log->tracef("trying to request complete_arg_elem to server");
                my $res = $args{riap_client}->request(
                    complete_arg_elem => $args{riap_server_url},
                    {(uri=>$args{riap_uri}) x !!defined($args{riap_uri}),
                     arg=>$arg, word=>$word, ci=>$ci,
                     index=>$index},
                );
                if ($res->[0] != 200) {
                    $log->tracef("request failed (%s), declining", $res);
                    return; # from eval
                }
                $reply = $res->[2];
                return; # from eval
            }

            $log->tracef("declining");
            return; # from eval
        }

        my $sch = $arg_p->{schema};
        unless ($sch) {
            $log->tracef("arg spec does not specify schema, declining");
            return; # from eval
        };

        # XXX normalize if not normalized

        my ($type, $cs) = @{ $sch };
        if ($type ne 'array') {
            $log->tracef("Can't complete element for non-array");
            return; # from element
        }

        unless ($cs->{of}) {
            $log->tracef("schema does not specify 'of' clause, declining");
            return; # from eval
        }

        # normalize subschema because normalize_schema (as of 0.01) currently
        # does not do it yet
        my $elsch = Data::Sah::Normalize::normalize_schema($cs->{of});

        $log->tracef("completing using element schema [$index]");
        $reply = complete_from_schema(schema=>$elsch, word=>$word, ci=>$ci);
    };
    $log->debug("Completion died: $@") if $@;
    unless ($reply) {
        $log->tracef("no completion from metadata possible, declining");
        return undef;
    }

    $reply;
}

sub _hashify {
    return $_[0] if ref($_[0]) eq 'HASH';
    {completion=>$_[0]};
}

$SPEC{complete_cli_arg} = {
    v => 1.1,
    summary => 'Complete command-line argument using Rinci function metadata',
    description => <<'_',

This routine uses `Perinci::Sub::GetArgs::Argv` to generate `Getopt::Long`
specification from arguments list in Rinci function metadata and common options.
Then, it will use `Complete::Getopt::Long` to complete option names, option
values, as well as arguments.

_
    args => {
        meta => {
            summary => 'Rinci function metadata',
            schema => 'hash*',
            req => 1,
        },
        words => {
            summary => 'Command-line arguments',
            schema => ['array*' => {of=>'str*'}],
            req => 1,
        },
        cword => {
            summary => 'On which argument cursor is located (zero-based)',
            schema => 'int*',
            req => 1,
        },
        completion => {
            summary => 'Supply custom completion routine',
            description => <<'_',

If supplied, instead of the default completion routine, this code will be called
instead. Will receive all arguments that `Complete::Getopt::Long` will pass, and
additionally:

* `extras` (hash)
* `arg` (str)
* `index` (int, if completing argument element value)

_
            schema => 'code*',
        },
        per_arg_json => {
            summary => 'Will be passed to Perinci::Sub::GetArgs::Argv',
            schema  => 'bool',
        },
        per_arg_yaml => {
            summary => 'Will be passed to Perinci::Sub::GetArgs::Argv',
            schema  => 'bool',
        },
        common_opts => {
            summary => 'Common options',
            description => <<'_',

A hash where the values are hashes containing these keys: `getopt` (Getopt::Long
option specification), `handler` (Getopt::Long handler). Will be passed to
`get_args_from_argv()`. Example:

    {
        help => {
            getopt  => 'help|h|?',
            handler => sub { ... },
            summary => 'Display help and exit',
        },
        version => {
            getopt  => 'version|v',
            handler => sub { ... },
            summary => 'Display version and exit',
        },
    }

_
            schema => ['hash*'],
        },
        extras => {
            summary => 'A hash that contains extra stuffs',
            description => <<'_',

Usually used to let completion routine get extra stuffs.

_
            schema  => 'hash',
        },
        %common_args_riap,
    },
    result_naked => 1,
    result => {
        schema => 'hash*',
        description => <<'_',

You can use `format_completion` function in `Complete::Bash` module to format
the result of this function for bash.

_
    },
};
sub complete_cli_arg {
    require Complete::Getopt::Long;
    require Perinci::Sub::GetArgs::Argv;

    my %args   = @_;
    my $meta   = $args{meta} or die "Please specify meta";
    my $words  = $args{words} or die "Please specify words";
    my $cword  = $args{cword}; defined($cword) or die "Please specify cword";
    my $copts  = $args{common_opts} // {};
    my $comp   = $args{completion};
    my $extras = $args{extras};

    my $word   = $words->[$cword];
    my $args_p = $meta->{args} // {};

    my $genres = Perinci::Sub::GetArgs::Argv::gen_getopt_long_spec_from_meta(
        meta         => $meta,
        common_opts  => $copts,
        per_arg_json => $args{per_arg_json},
        per_arg_yaml => $args{per_arg_yaml},
    );
    die "Can't generate getopt spec from meta: $genres->[0] - $genres->[1]"
        unless $genres->[0] == 200;
    my $gospec = $genres->[2];
    my $specmeta = $genres->[3]{'func.specmeta'};

    my $copts_by_ospec = {};
    for (keys %$copts) { $copts_by_ospec->{$copts->{$_}{getopt}}=$copts->{$_} }

    my $compgl_comp = sub {
        $log->tracef("completing cli arg with rinci metadata");
        my %cargs = @_;
        my $type  = $cargs{type};
        my $ospec = $cargs{ospec} // '';
        my $word  = $cargs{word};
        my $ci    = $cargs{ci};

        $cargs{extras} = $extras;

        my %rargs = (
            riap_server_url => $args{riap_server_url},
            riap_uri        => $args{riap_uri},
            riap_client     => $args{riap_client},
        );

        if (my $sm = $specmeta->{$ospec}) {
            $cargs{type} = 'optval';
            if ($sm->{arg}) {
                $log->tracef("completing option value for a known function argument (ospec: %s, arg: %s)", $ospec, $sm->{arg});
                $cargs{arg} = $sm->{arg};
                my $as = $args_p->{$sm->{arg}} or return undef;
                if ($comp) {
                    $log->tracef("completing with 'completion' routine");
                    my $res;
                    eval { $res = $comp->(%cargs) };
                    $log->debug("completion died: $@") if $@;
                    return $res if $res;
                }
                if ($ospec =~ /\@$/) {
                    return complete_arg_elem(
                        meta=>$meta, arg=>$sm->{arg}, word=>$word, index=>$cargs{nth}, # XXX correct index
                        extras=>$extras, %rargs);
                } else {
                    return complete_arg_val(
                        meta=>$meta, arg=>$sm->{arg}, word=>$word,
                        extras=>$extras, %rargs);
                }
            } else {
                $log->tracef("completing option value for a common option (ospec: %s)", $ospec);
                $cargs{arg}  = undef;
                my $codata = $copts_by_ospec->{$ospec};
                if ($comp) {
                    $log->tracef("completing with 'completion' routine");
                    my $res;
                    eval { $res = $comp->(%cargs) };
                    $log->debug("completion died: $@") if $@;
                    return $res if $res;
                }
                if ($codata->{completion}) {
                    $cargs{arg}  = undef;
                    $log->tracef("completing with common option's completion");
                    my $res;
                    eval { $res = $codata->{completion}->(%cargs) };
                    $log->debug("completion died: $@") if $@;
                    return $res if $res;
                }
                if ($codata->{schema}) {
                    require Data::Sah::Normalize;
                    my $nsch = Data::Sah::Normalize::normalize_schema(
                        $codata->{schema});
                    $log->tracef("completing with common option's schema");
                    return complete_from_schema(
                        schema => $nsch, word=>$word, ci=>$ci);
                }
                return undef;
            }
        } elsif ($type eq 'arg') {
            $log->tracef("completing positional cli argument #%d", $cargs{argpos});
            $cargs{type} = 'arg';

            my $pos = $cargs{argpos};

            # find if there is a non-greedy argument with the exact position
            for my $an (keys %$args_p) {
                my $as = $args_p->{$an};
                next unless !$as->{greedy} &&
                    defined($as->{pos}) && $as->{pos} == $pos;
                $log->tracef("this position is for non-greedy function argument %s", $an);
                $cargs{arg} = $an;
                if ($comp) {
                    $log->tracef("completing with 'completion' routine");
                    my $res;
                    eval { $res = $comp->(%cargs) };
                    $log->debug("completion died: $@") if $@;
                    return $res if $res;
                }
                return complete_arg_val(
                    meta=>$meta, arg=>$an, word=>$word,
                    extras=>$extras, %rargs);
            }

            # find if there is a greedy argument which takes elements at that
            # position
            for my $an (sort {
                ($args_p->{$b}{pos} // 9999) <=> ($args_p->{$a}{pos} // 9999)
            } keys %$args_p) {
                my $as = $args_p->{$an};
                next unless $as->{greedy} &&
                    defined($as->{pos}) && $as->{pos} <= $pos;
                my $index = $pos - $as->{pos};
                $cargs{arg} = $an;
                $cargs{index} = $index;
                $log->tracef("this position is for greedy function argument %s's element[%d]", $an, $index);
                if ($comp) {
                    $log->tracef("completing with 'completion' routine");
                    my $res;
                    eval { $res = $comp->(%cargs) };
                    $log->debug("completion died: $@") if $@;
                    return $res if $res;
                }
                return complete_arg_elem(
                    meta=>$meta, arg=>$an, word=>$word, index=>$index,
                    extras=>$extras, %rargs);
            }

            $log->tracef("there is no matching function argument at this position");
            if ($comp) {
                $log->tracef("completing with 'completion' routine");
                my $res;
                eval { $res = $comp->(%cargs) };
                $log->debug("completion died: $@") if $@;
                return $res if $res;
            }
            return undef;
        } else {
            $log->tracef("completing option value for an unknown/ambiguous option, declining ...");
            # decline because there's nothing in Rinci metadata that can aid us
            return undef;
        }
    };

    Complete::Getopt::Long::complete_cli_arg(
        getopt_spec => $gospec,
        words       => $words,
        cword       => $cword,
        completion  => $compgl_comp,
        extras      => $extras,
    );
}

1;
# ABSTRACT: Complete command-line argument using Rinci metadata

__END__

=pod

=encoding UTF-8

=head1 NAME

Perinci::Sub::Complete - Complete command-line argument using Rinci metadata

=head1 VERSION

This document describes version 0.60 of Perinci::Sub::Complete (from Perl distribution Perinci-Sub-Complete), released on 2014-07-29.

=head1 SYNOPSIS

See L<Perinci::CmdLine> or L<Perinci::CmdLine::Lite> or L<App::riap> which use
this module.

=head1 DESCRIPTION

=head1 FUNCTIONS


=head2 complete_arg_elem(%args) -> array

Given argument name and function metadata, complete array element.

Will attempt to complete using the completion routine specified in the argument
specification, or if that is not specified, from argument's schema using
C<complete_from_schema>.

Arguments ('*' denotes required arguments):

=over 4

=item * B<arg>* => I<str>

Argument name.

=item * B<args> => I<hash>

Collected arguments so far, will be passed to completion routines.

=item * B<ci> => I<bool> (default: 0)

Whether to be case-insensitive.

=item * B<extras> => I<hash>

To pass extra arguments to completion routines.

=item * B<index> => I<int>

Index of element to complete.

=item * B<meta>* => I<hash>

Rinci function metadata, must be normalized.

=item * B<riap_client> => I<obj>

Optional, to perform complete_arg_val to the server.

When the argument spec in the Rinci metadata contains C<completion> key, this
means there is custom completion code for that argument. However, if retrieved
from a remote server, sometimes the C<completion> key no longer contains the code
(it has been cleansed into a string). Moreover, the completion code needs to run
on the server.

If supplied this argument and te C<riap_server_url> argument, the function will
try to request to the server (via Riap request C<complete_arg_val>). Otherwise,
the function will just give up/decline completing.

=item * B<riap_server_url> => I<str>

Optional, to perform complete_arg_val to the server.

See the C<riap_client> argument.

=item * B<riap_uri> => I<str>

Optional, to perform complete_arg_val to the server.

See the C<riap_client> argument.

=item * B<word> => I<str> (default: "")

Word to be completed.

=back

Return value:

 (array)


=head2 complete_arg_val(%args) -> array

Given argument name and function metadata, complete value.

Will attempt to complete using the completion routine specified in the argument
specification, or if that is not specified, from argument's schema using
C<complete_from_schema>.

Arguments ('*' denotes required arguments):

=over 4

=item * B<arg>* => I<str>

Argument name.

=item * B<args> => I<hash>

Collected arguments so far, will be passed to completion routines.

=item * B<ci> => I<bool> (default: 0)

Whether to be case-insensitive.

=item * B<extras> => I<hash>

To pass extra arguments to completion routines.

=item * B<meta>* => I<hash>

Rinci function metadata, must be normalized.

=item * B<riap_client> => I<obj>

Optional, to perform complete_arg_val to the server.

When the argument spec in the Rinci metadata contains C<completion> key, this
means there is custom completion code for that argument. However, if retrieved
from a remote server, sometimes the C<completion> key no longer contains the code
(it has been cleansed into a string). Moreover, the completion code needs to run
on the server.

If supplied this argument and te C<riap_server_url> argument, the function will
try to request to the server (via Riap request C<complete_arg_val>). Otherwise,
the function will just give up/decline completing.

=item * B<riap_server_url> => I<str>

Optional, to perform complete_arg_val to the server.

See the C<riap_client> argument.

=item * B<riap_uri> => I<str>

Optional, to perform complete_arg_val to the server.

See the C<riap_client> argument.

=item * B<word> => I<str> (default: "")

Word to be completed.

=back

Return value:

 (array)


=head2 complete_cli_arg(%args) -> hash

Complete command-line argument using Rinci function metadata.

This routine uses C<Perinci::Sub::GetArgs::Argv> to generate C<Getopt::Long>
specification from arguments list in Rinci function metadata and common options.
Then, it will use C<Complete::Getopt::Long> to complete option names, option
values, as well as arguments.

Arguments ('*' denotes required arguments):

=over 4

=item * B<common_opts> => I<hash>

Common options.

A hash where the values are hashes containing these keys: C<getopt> (Getopt::Long
option specification), C<handler> (Getopt::Long handler). Will be passed to
C<get_args_from_argv()>. Example:

 {
     help => {
         getopt  => 'help|h|?',
         handler => sub { ... },
         summary => 'Display help and exit',
     },
     version => {
         getopt  => 'version|v',
         handler => sub { ... },
         summary => 'Display version and exit',
     },
 }

=item * B<completion> => I<code>

Supply custom completion routine.

If supplied, instead of the default completion routine, this code will be called
instead. Will receive all arguments that C<Complete::Getopt::Long> will pass, and
additionally:

=over

=item * C<extras> (hash)

=item * C<arg> (str)

=item * C<index> (int, if completing argument element value)

=back

=item * B<cword>* => I<int>

On which argument cursor is located (zero-based).

=item * B<extras> => I<hash>

A hash that contains extra stuffs.

Usually used to let completion routine get extra stuffs.

=item * B<meta>* => I<hash>

Rinci function metadata.

=item * B<per_arg_json> => I<bool>

Will be passed to Perinci::Sub::GetArgs::Argv.

=item * B<per_arg_yaml> => I<bool>

Will be passed to Perinci::Sub::GetArgs::Argv.

=item * B<riap_client> => I<obj>

Optional, to perform complete_arg_val to the server.

When the argument spec in the Rinci metadata contains C<completion> key, this
means there is custom completion code for that argument. However, if retrieved
from a remote server, sometimes the C<completion> key no longer contains the code
(it has been cleansed into a string). Moreover, the completion code needs to run
on the server.

If supplied this argument and te C<riap_server_url> argument, the function will
try to request to the server (via Riap request C<complete_arg_val>). Otherwise,
the function will just give up/decline completing.

=item * B<riap_server_url> => I<str>

Optional, to perform complete_arg_val to the server.

See the C<riap_client> argument.

=item * B<riap_uri> => I<str>

Optional, to perform complete_arg_val to the server.

See the C<riap_client> argument.

=item * B<words>* => I<array>

Command-line arguments.

=back

Return value:

 (hash)

You can use C<format_completion> function in C<Complete::Bash> module to format
the result of this function for bash.


=head2 complete_from_schema(%args) -> [status, msg, result, meta]

Complete a value from schema.

Employ some heuristics to complete a value from Sah schema. For example, if
schema is C<< [str =E<gt> in =E<gt> [qw/new open resolved rejected/]] >>, then we can
complete from the C<in> clause. Or for something like C<< [int =E<gt> between =E<gt> [1,
20]] >> we can complete using values from 1 to 20.

Arguments ('*' denotes required arguments):

=over 4

=item * B<ci> => I<bool>

=item * B<schema>* => I<any>

Must be normalized.

=item * B<word>* => I<str> (default: "")

=back

Return value:

Returns an enveloped result (an array).

First element (status) is an integer containing HTTP status code
(200 means OK, 4xx caller error, 5xx function error). Second element
(msg) is a string containing error message, or 'OK' if status is
200. Third element (result) is optional, the actual result. Fourth
element (meta) is called result metadata and is optional, a hash
that contains extra information.

 (any)

=for Pod::Coverage ^(.+)$

=head1 SEE ALSO

L<Complete>, L<Complete::Getopt::Long>

L<Perinci::CmdLine>, L<Perinci::CmdLine::Lite>, L<App::riap>

=head1 HOMEPAGE

Please visit the project's homepage at L<https://metacpan.org/release/Perinci-Sub-Complete>.

=head1 SOURCE

Source repository is at L<https://github.com/sharyanto/perl-Perinci-Sub-Complete>.

=head1 BUGS

Please report any bugs or feature requests on the bugtracker website L<https://rt.cpan.org/Public/Dist/Display.html?Name=Perinci-Sub-Complete>

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
