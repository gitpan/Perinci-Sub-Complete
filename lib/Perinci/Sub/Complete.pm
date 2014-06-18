package Perinci::Sub::Complete;

use 5.010001;
use strict;
use warnings;
use experimental 'smartmatch';
use Log::Any '$log';

use Data::Clone;
#use List::MoreUtils qw(firstidx);
use SHARYANTO::Complete::Util qw(
                                    complete_array
                                    complete_env
                                    complete_file
                                    parse_shell_cmdline
                            );

our $VERSION = '0.39'; # VERSION

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(
                       complete_from_schema
                       complete_arg_val
                       complete_arg_elem
                       shell_complete_arg
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

If supplied this argument, `riap_server_url`, and the `riap_uri` arguments, the
function will try to request to the server (via Riap request
`complete_arg_val`). Otherwise, the function will just give up/decline
completing.

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
                push @$words, $cs->{min}+1 .. $cs->{max}-1;
            }
        }
    }; # eval

    return undef unless $words;
    complete_array(array=>$words, word=>$word, ci=>$ci);
}

$SPEC{complete_arg_val} = {
    v => 1.1,
    summary => 'Given argument name and function metadata, complete value',
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
        parent_args => {
            summary => 'To pass parent arguments to completion routines',
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
    my $ci   = $args{ci} // 0;
    my $word = $args{word} // '';

    # XXX reject if meta's v is not 1.1

    my $args_p = $meta->{args} // {};
    my $arg_p = $args_p->{$arg} or do {
        $log->tracef("arg '$arg' is not specified in meta, declining");
        return undef;
    };

    my $words;
    eval { # completion sub can die, etc.

        my $comp = $arg_p->{completion};
        if ($comp) {
            $log->tracef("calling arg spec's completion");
            if (ref($comp) eq 'CODE') {
                $words = $comp->(
                    word=>$word, ci=>$ci, args=>$args{args},
                    parent_args=>\%args);
                die "Completion sub does not return array"
                    unless ref($words) eq 'ARRAY';
                return; # from eval
            }

            $log->tracef("arg spec's completion is not a coderef");
            if ($args{riap_client} && $args{riap_server_url}
                    && $args{riap_uri}) {
                $log->tracef("trying to do complete_arg_val from the server");
                my $res = $args{riap_client}->request(
                    complete_arg_val => $args{riap_server_url},
                    {uri=>$args{riap_uri}, arg=>$arg, word=>$word, ci=>$ci},
                );
                if ($res->[0] != 200) {
                    $log->tracef("request failed (%s), declining", $res);
                    return; # from eval
                }
                $words = $res->[2];
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
        $words = complete_from_schema(schema=>$sch, word=>$word, ci=>$ci);
    };
    $log->debug("Completion died: $@") if $@;
    unless ($words) {
        $log->tracef("no completion from metadata possible, declining");
        return undef;
    }
    complete_array(array=>$words, word=>$word, ci=>$ci);
}

my $m = clone($SPEC{complete_arg_val});
$m->{summary} = 'Given argument name and function metadata, complete array element';
$m->{args}{index} = {
    summary => 'Index of element to complete',
    schema  => [int => min => 0],
};
$SPEC{complete_arg_elem} = $m;
sub complete_arg_elem {
    require Data::Sah;

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
    my $ci   = $args{ci} // 0;
    my $word = $args{word} // '';

    # XXX reject if meta's v is not 1.1

    my $args_p = $meta->{args} // {};
    my $arg_p = $args_p->{$arg} or do {
        $log->tracef("arg '$arg' is not specified in meta, declining");
        return undef;
    };

    my $words;
    eval { # completion sub can die, etc.

        my $elcomp = $arg_p->{element_completion};
        if ($elcomp) {
            $log->tracef("calling arg spec's element_completion");
            if (ref($elcomp) eq 'CODE') {
                $words = $elcomp->(
                    word=>$word, ci=>$ci, index=>$index,
                    args=>$args{args}, parent_args=>\%args);
                die "Completion sub does not return array"
                    unless ref($words) eq 'ARRAY';
                return; # from eval
            }

            $log->tracef("arg spec's element_completion is not a coderef");
            if ($args{riap_client} && $args{riap_server_url} &&
                    $args{riap_uri}) {
                $log->tracef("trying to do complete_arg_elem from the server");
                my $res = $args{riap_client}->request(
                    complete_arg_elem => $args{riap_server_url},
                    {uri=>$args{riap_uri}, arg=>$arg, word=>$word, ci=>$ci,
                     index=>$index},
                );
                if ($res->[0] != 200) {
                    $log->tracef("request failed (%s), declining", $res);
                    return; # from eval
                }
                $words = $res->[2];
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

        # normalize subschema since periwrap does not currently do it
        my $elsch = Data::Sah::normalize_schema($cs->{of});

        $log->tracef("completing using element schema");
        $words = complete_from_schema(schema=>$elsch, word=>$word, ci=>$ci);
    };
    $log->debug("Completion died: $@") if $@;
    unless ($words) {
        $log->tracef("no completion from metadata possible, declining");
        return undef;
    }
    complete_array(array=>$words, word=>$word, ci=>$ci);
}

$SPEC{shell_complete_arg} = {
    v => 1.1,
    summary => 'Complete command-line argument using Rinci function metadata',
    description => <<'_',

Assuming that command-line like:

    foo a b c

is executing some function, and the command-line arguments will be parsed using
`Perinci::Sub::GetArgs::Argv`, then try to complete command-line arguments using
information from Rinci metadata.

Algorithm:

1. If word begins with `$`, we complete from environment variables and are done.

2. Call `get_args_from_argv()` to extract hash arguments from the given `words`.

3. Determine whether we need to complete argument name (e.g. `--arg<tab>`) or
argument value (e.g. `--arg1 <tab>` or `<tab>` at 1st word where there is an
argument specified at pos=0) or an element for an array argument (e.g. `a <tab>`
where there is an argument with spec pos=0 and greedy=1, which means we are
trying to complete the value of the second element (index=1) of that argument).

4. Call `custom_completer` if defined. If a list of words is returned, we're
done. This can be used for, e.g. nested function call, e.g.:

    somecmd --opt-for-cmd ... subcmd --opt-for-subcmd ...

5a. If we are completing argument name, then supply a list of possible argument
names, or fallback to completing filenames.

5b. If we are completing argument value, first check if `custom_arg_completer`
is defined. If yes, call that routine. If a list of words is returned, we're
done. Fallback to completing argument values from information in Rinci metadata
(using `complete_arg_val()` function).

5c. If we are completing value for an element, first check if
`custom_arg_element_completer` is defined. If yes, call that routine. If a list
of words is returned, we're done. Fallback to completing argument values from
information in Rinci metadata (using `complete_arg_val()` function).

_
    args => {
        meta => {
            summary => 'Rinci function metadata, must be normalized',
            schema => 'hash*',
            req => 1,
        },
        words => {
            summary => 'Command-line, broken as words',
            schema => ['array*' => {of=>'str*'}],
            description => <<'_',

If unset, will be taken from COMP_LINE and COMP_POINT.

_
        },
        cword => {
            summary => 'On which word cursor is located (zero-based)',
            description => <<'_',

If unset, will be taken from COMP_LINE and COMP_POINT.

_
            schema => 'int*',
        },
        custom_completer => {
            summary => 'Supply custom completion routine',
            description => <<'_',

If supplied, instead of the default completion routine, this code will be called
instead. Refer to function description to see when this routine is called.

Code will be called with a hash argument, with these keys: `which` (a string
with value `name` or `value` depending on whether we should complete argument
name or value), `words` (an array, the command line split into words), `cword`
(int, position of word in `words`), `word` (the word to be completed),
`parent_args` (hash, arguments given to `shell_complete_arg()`), `args` (hash,
parsed function arguments from `words`) `remaining_words` (array, slice of
`words` after `cword`), `meta` (the Rinci function metadata).

Code should return an arrayref of completion, or `undef` to declare declination,
on which case completion will resume using the standard builtin routine.

A use-case of using this option: XXX.

_
            schema => 'code*',
        },
        custom_arg_completer => {
            summary => 'Supply custom argument value completion routines',
            description => <<'_',

Either code or a hash of argument names and codes.

If supplied, instead of the default completion routine, this code will be called
instead when trying to complete argument value. Refer to function description to
see when this routine is called.

Code will be called with hash arguments containing these keys: `word` (string,
the word to be completed), `arg` (string, the argument name that we are
completing the value of), `args` (hash, the arguments that have been collected
so far), `parent_args`.

A use-case for using this option: getting argument value from Riap client using
the `complete_arg_val` action. This allows getting completion from remote
server.

_
            schema=>['any*' => {
                of => [
                    'code*',
                    ['hash*'=>{
                        #values=>'code*', # temp: disabled, not supported yet by Data::Sah
                    }],
                ]}],
        },
        custom_arg_element_completer => {
            summary => 'Supply custom argument element completion routines',
            description => <<'_',

Either code or a hash of argument names and codes.

If supplied, instead of the default completion routine, this code will be called
instead when trying to complete argument element. Refer to function description
to see when this routine is called.

Code will be called with hash arguments containing these keys: `word` (string,
the word to be completed), `arg` (string, the argument name that we are
completing the value of), `args` (hash, the arguments that have been collected
so far), `parent_args`, `idx` (the element index that we are are trying to
complete, starts from 0).

_
            schema=>['any*' => {
                of => [
                    'code*',
                    ['hash*'=>{
                        #values=>'code*', # temp: disabled, not supported yet by Data::Sah
                    }],
                ]}],
        },
        common_opts => {
            summary => 'Common options',
            description => <<'_',

When completing argument name, this list will be added.

_
            schema => ['array*' => {
                of=>['any*' => {of=>['str*', ['array*'=>{of=>'str*'}]]}],
                default=>[['--help', '-?', '-h']],
            }],
        },
        extra_completer_args => {
            summary => 'Arguments to pass to custom completion routines',
            schema  => 'hash*',
            description => <<'_',

Completion routines will get this from their `parent_args` argument.

_
        },
        %common_args_riap,
    },
    result_naked => 1,
    result => {
        schema => 'array*', # XXX of => str*
    },
};
sub shell_complete_arg {
    require Perinci::Sub::GetArgs::Argv;
    require UUID::Random;

    my %args = @_;
    $log->tracef("=> complete_arg(%s)", \%args);
    my $meta  = $args{meta} or die "Please specify meta";
    my $words = $args{words};
    my $cword = $args{cword} // 0;
    if (!$words) {
        my $res = parse_shell_cmdline();
        $words = $res->{words};
        $cword = $res->{cword};
    }
    my $word = $words->[$cword] // "";

    my $res;

    $log->tracef("words=%s, cword=%d, word=%s", $words, $cword, $word);

    if ($word =~ /^\$/) {
        $log->tracef("word begins with \$, completing env vars");
        return complete_env(word=>$word);
    }

    if ((my $v = $meta->{v} // 1.0) != 1.1) {
        $log->debug("Metadata version is not supported ($v), ".
                        "only 1.1 is supported");
        return [];
    }
    my $args_p = $meta->{args} // {};

    # first, we stick a unique ID at cword to be able to check whether we should
    # complete arg name or arg value.
    my $which = 'name';
    my $arg;
    my $index;
    my $remaining_words = [@$words];

    my $uuid = UUID::Random::generate();
    my $orig_word = $remaining_words->[$cword];
    $remaining_words->[$cword] = $uuid;
    $res = Perinci::Sub::GetArgs::Argv::get_args_from_argv(
        argv=>$remaining_words, meta=>$meta, strict=>0);
    if ($res->[0] != 200) {
        $log->debug("Failed getting args from argv: $res->[0] - $res->[1]");
        return [];
    }
    my $args = $res->[2];
  ARG:
    for my $an (keys %$args) {
        if (defined($args->{$an})) {
        if ($args_p->{$an} && $args_p->{$an}{greedy}) {
            $which = 'element value';
            $arg = $an;
            if (ref($args->{$an}) eq 'ARRAY') {
                for my $i (0..@{ $args->{$an} }-1) {
                    if ($args->{$an}[$i] eq $uuid) {
                        $index = $i;
                        $args->{$an}[$i] = undef;
                        last ARG;
                    }
                }
            } else {
                # this is not perfect as whitespaces have been mashed together
                my @els = split /\s+/, $args->{$an};
                for my $i (0..$#els) {
                    if ($els[$i] eq $uuid) {
                        $index = $i;
                        $els[$i] = '';
                        $args->{$an} = join " ", @els;
                        last ARG;
                    }
                }
            }
        } elsif ($args->{$an} eq $uuid) {
                $arg = $an;
                $which = 'value';
                $args->{$an} = undef;
                last;
            }
        }
    }
    # restore original word which we replaced with uuid earlier (we can't simply
    # use local $remaining_words->[$cword] = $uuid because the $remaining_words
    # array might already be sliced by get_args_from_argv())
    for my $i (0..@$remaining_words-1) {
        if (defined($remaining_words->[$i]) &&
                $remaining_words->[$i] eq $uuid) {
            $remaining_words->[$i] = $orig_word;
        }
    }
    # shave undef at the end because it might be formed when doing '--arg1
    # <tab>' (XXX but why?) if we don't shave it, it will be assumed as '--arg1
    # undef' and we move on to next arg name, when we should complete arg1's
    # value.
    pop @$remaining_words
        while (@$remaining_words && !defined($remaining_words->[-1]));

    if ($which ne 'name' && $word =~ /^-/) {
        # user indicates he wants to complete arg name
        $which = 'name';
        delete $args->{$arg} if !defined($args->{$arg});
    } elsif ($which ne 'value' && $word =~ /^--([\w-]+)=(.*)/) {
        $arg = $1;
        $word = $words->[$cword] = $2;
        $which = 'value';
    }
    if ($which eq 'name') {
        $log->tracef("we should complete arg name, word=<%s>", $word);
    } elsif ($which eq 'value') {
        $log->tracef("we should complete arg value, arg=<%s>, word=<%s>",
                 $arg, $word);
    } elsif ($which eq 'element value') {
        $log->tracef("we should complete arg element value, ".
                         "arg=<%s>, index=%s, word=<%s>",
                     $arg, $index, $word);
    }

    if ($args{custom_completer}) {
        $log->tracef("calling 'custom_completer'");
        # custom_completer can decline by returning undef
        my $newcword = $cword - (@$words - @$remaining_words);
        $newcword = 0 if $newcword < 0;
        $res = $args{custom_completer}->(
            which => $which,
            words => $words,
            cword => $newcword,
            word  => $word,
            index => $index, # for which='element value'
            args  => $args,
            parent_args => \%args,
            meta  => $meta,
            remaining_words => $remaining_words,
        );
        $log->tracef("custom_completer returns %s", $res);
        if ($res) {
            return complete_array(word=>$word, array=>$res);
        }
    }

    if ($which eq 'value') {

        my $cac = $args{custom_arg_completer};
        if ($cac) {
            if (ref($cac) eq 'HASH') {
                if ($cac->{$arg}) {
                    $log->tracef("calling 'custom_arg_completer'->{%s}", $arg);
                    $res = $cac->{$arg}->(
                        word=>$word, arg=>$arg, args=>$args,
                        parent_args=>\%args,
                    );
                    $log->tracef("custom_arg_completer returns %s", $res);
                    if ($res) {
                        return complete_array(word => $word, array => $res);
                    }
                }
            } else {
                $log->tracef("calling 'custom_arg_completer' (arg=%s)", $arg);
                $res = $cac->(
                    word=>$word, arg=>$arg, args=>$args, parent_args=>\%args);
                $log->tracef("custom_arg_completer returns %s", $res);
                if ($res) {
                    return complete_array(word => $word, array => $res);
                }
            }
        }

        $log->tracef("completing using complete_arg_val()");
        $res = complete_arg_val(
            meta=>$meta, arg=>$arg, word=>$word,
            args=>$args, parent_args=>\%args,
            riap_server_url => $args{riap_server_url},
            riap_uri        => $args{riap_uri},
            riap_client     => $args{riap_client},
        );
        $log->tracef("complete_arg_val() returns %s", $res);
        return $res if $res;

        # fallback to file
        $log->tracef("completing arg value from file (fallback)");
        return complete_file(word=>$word);

    } elsif ($which eq 'element value') {

        my $caec = $args{custom_arg_element_completer};
        if ($caec) {
            if (ref($caec) eq 'HASH') {
                if ($caec->{$arg}) {
                    $log->tracef("calling 'custom_arg_element_completer'->{%s}", $arg);
                    $res = $caec->{$arg}->(
                        word=>$word, arg=>$arg, args=>$args, index=>$index,
                        parent_args=>\%args,
                    );
                    $log->tracef("custom_arg_element_completer returns %s", $res);
                    if ($res) {
                        return complete_array(word=>$word, array=>$res);
                    }
                }
            } else {
                $log->tracef("calling 'custom_arg_element_completer' (arg=%s)", $arg);
                $res = $caec->(
                    word=>$word, arg=>$arg, args=>$args, index=>$index,
                    parent_args=>\%args);
                $log->tracef("custom_arg_element_completer returns %s", $res);
                if ($res) {
                    return complete_array(word=>$word, array=>$res);
                }
            }
        }

        $log->tracef("completing using complete_arg_elem()");
        $res = complete_arg_elem(
            meta=>$meta, arg=>$arg, word=>$word, index=>$index,
            args=>$args, parent_args=>\%args,
            riap_server_url => $args{riap_server_url},
            riap_uri        => $args{riap_uri},
            riap_client     => $args{riap_client},
        );
        $log->tracef("complete_arg_elem() returns %s", $res);
        return $res if $res;

        # fallback to file
        $log->tracef("completing arg element value from file (fallback)");
        return complete_file(word=>$word);

    } elsif ($word eq '' || $word =~ /^--?/) {
        # which eq 'name'

        # find completable args (the one that has not been mentioned or should
        # always be mentioned)

        my @words;
      ARG:
        for my $a0 (keys %$args_p) {
            my $as = $args_p->{$a0};
            next if exists($args->{$a0}) && (!$as || !$as->{greedy});
            my @a;
            push @a, $a0;
            if ($as->{cmdline_aliases}) {
                push @a, $_ for keys %{$as->{cmdline_aliases}};
            }
            for my $a (@a) {
                $a =~ s/[_.]/-/g;
                my @w;
                my $type = $as->{schema}[0];
                if ($type eq 'bool' && length($a) > 1 &&
                        !$as->{schema}[1]{is}) {
                    @w = ("--$a", "--no$a");
                } else {
                    @w = length($a) == 1 ? ("-$a") : ("--$a");
                }
                push @words, @w;
            }
        }

        my $special_opts = [];
        my $ff = $meta->{features} // {};
        if ($ff->{dry_run}) {
            push @$special_opts, ['--dry-run'];
        }

        my $common_opts = $args{common_opts} // [['--help', '-h', '-?']];

      CO:
        for my $co (@$special_opts, @$common_opts) {
            if (ref($co) eq 'ARRAY') {
                for (@$co) { next CO if $_ ~~ @$words || $_ ~~ @words }
                push @words, @$co;
            } else {
                push @words, $co unless $co ~~ @$words || $co ~~ @words;
            }
        }

        return complete_array(word=>$word, array=>\@words);

    } else {

        # fallback
        return complete_file(word=>$word);

    }
}

1;
# ABSTRACT: Shell completion routines using Rinci metadata

__END__

=pod

=encoding UTF-8

=head1 NAME

Perinci::Sub::Complete - Shell completion routines using Rinci metadata

=head1 VERSION

This document describes version 0.39 of Perinci::Sub::Complete (from Perl distribution Perinci-Sub-Complete), released on 2014-06-18.

=head1 SYNOPSIS

=head1 DESCRIPTION

This module provides functionality for doing shell completion. It is meant to be
used by L<Perinci::CmdLine> and other L<Rinci>/L<Riap>-based CLI shell like
L<App::riap>.

=head1 FUNCTIONS


=head2 complete_arg_elem(%args) -> array

Given argument name and function metadata, complete array element.

Arguments ('*' denotes required arguments):

=over 4

=item * B<arg>* => I<str>

Argument name.

=item * B<args> => I<hash>

Collected arguments so far, will be passed to completion routines.

=item * B<ci> => I<bool> (default: 0)

Whether to be case-insensitive.

=item * B<index> => I<int>

Index of element to complete.

=item * B<meta>* => I<hash>

Rinci function metadata, must be normalized.

=item * B<parent_args> => I<hash>

To pass parent arguments to completion routines.

=item * B<riap_client> => I<obj>

Optional, to perform complete_arg_val to the server.

When the argument spec in the Rinci metadata contains C<completion> key, this
means there is custom completion code for that argument. However, if retrieved
from a remote server, sometimes the C<completion> key no longer contains the code
(it has been cleansed into a string). Moreover, the completion code needs to run
on the server.

If supplied this argument, C<riap_server_url>, and the C<riap_uri> arguments, the
function will try to request to the server (via Riap request
C<complete_arg_val>). Otherwise, the function will just give up/decline
completing.

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


=head2 complete_arg_val(%args) -> array

Given argument name and function metadata, complete value.

Arguments ('*' denotes required arguments):

=over 4

=item * B<arg>* => I<str>

Argument name.

=item * B<args> => I<hash>

Collected arguments so far, will be passed to completion routines.

=item * B<ci> => I<bool> (default: 0)

Whether to be case-insensitive.

=item * B<meta>* => I<hash>

Rinci function metadata, must be normalized.

=item * B<parent_args> => I<hash>

To pass parent arguments to completion routines.

=item * B<riap_client> => I<obj>

Optional, to perform complete_arg_val to the server.

When the argument spec in the Rinci metadata contains C<completion> key, this
means there is custom completion code for that argument. However, if retrieved
from a remote server, sometimes the C<completion> key no longer contains the code
(it has been cleansed into a string). Moreover, the completion code needs to run
on the server.

If supplied this argument, C<riap_server_url>, and the C<riap_uri> arguments, the
function will try to request to the server (via Riap request
C<complete_arg_val>). Otherwise, the function will just give up/decline
completing.

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


=head2 complete_from_schema(%args) -> [status, msg, result, meta]

Complete a value from schema.

Employ some heuristics to complete a value from Sah schema. For example, if
schema is C<[str => in => [qw/new open resolved rejected/]]>, then we can
complete from the C<in> clause. Or for something like C<[int => between => [1,
20]]> we can complete using values from 1 to 20.

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


=head2 shell_complete_arg(%args) -> array

Complete command-line argument using Rinci function metadata.

Assuming that command-line like:

    foo a b c

is executing some function, and the command-line arguments will be parsed using
C<Perinci::Sub::GetArgs::Argv>, then try to complete command-line arguments using
information from Rinci metadata.

Algorithm:

=over

=item 1.

If word begins with C<$>, we complete from environment variables and are done.



=item 2.

Call C<get_args_from_argv()> to extract hash arguments from the given C<words>.



=item 3.

Determine whether we need to complete argument name (e.g. C<--arg<tab>>) or
argument value (e.g. C<--arg1 <tab>> or C<<tab>> at 1st word where there is an
argument specified at pos=0) or an element for an array argument (e.g. C<a <tab>>
where there is an argument with spec pos=0 and greedy=1, which means we are
trying to complete the value of the second element (index=1) of that argument).



=item 4.

Call C<custom_completer> if defined. If a list of words is returned, we're
done. This can be used for, e.g. nested function call, e.g.:

somecmd --opt-for-cmd ... subcmd --opt-for-subcmd ...



=back

5a. If we are completing argument name, then supply a list of possible argument
names, or fallback to completing filenames.

5b. If we are completing argument value, first check if C<custom_arg_completer>
is defined. If yes, call that routine. If a list of words is returned, we're
done. Fallback to completing argument values from information in Rinci metadata
(using C<complete_arg_val()> function).

5c. If we are completing value for an element, first check if
C<custom_arg_element_completer> is defined. If yes, call that routine. If a list
of words is returned, we're done. Fallback to completing argument values from
information in Rinci metadata (using C<complete_arg_val()> function).

Arguments ('*' denotes required arguments):

=over 4

=item * B<common_opts> => I<array> (default: [["--help", "-?", "-h"]])

Common options.

When completing argument name, this list will be added.

=item * B<custom_arg_completer> => I<code|hash>

Supply custom argument value completion routines.

Either code or a hash of argument names and codes.

If supplied, instead of the default completion routine, this code will be called
instead when trying to complete argument value. Refer to function description to
see when this routine is called.

Code will be called with hash arguments containing these keys: C<word> (string,
the word to be completed), C<arg> (string, the argument name that we are
completing the value of), C<args> (hash, the arguments that have been collected
so far), C<parent_args>.

A use-case for using this option: getting argument value from Riap client using
the C<complete_arg_val> action. This allows getting completion from remote
server.

=item * B<custom_arg_element_completer> => I<code|hash>

Supply custom argument element completion routines.

Either code or a hash of argument names and codes.

If supplied, instead of the default completion routine, this code will be called
instead when trying to complete argument element. Refer to function description
to see when this routine is called.

Code will be called with hash arguments containing these keys: C<word> (string,
the word to be completed), C<arg> (string, the argument name that we are
completing the value of), C<args> (hash, the arguments that have been collected
so far), C<parent_args>, C<idx> (the element index that we are are trying to
complete, starts from 0).

=item * B<custom_completer> => I<code>

Supply custom completion routine.

If supplied, instead of the default completion routine, this code will be called
instead. Refer to function description to see when this routine is called.

Code will be called with a hash argument, with these keys: C<which> (a string
with value C<name> or C<value> depending on whether we should complete argument
name or value), C<words> (an array, the command line split into words), C<cword>
(int, position of word in C<words>), C<word> (the word to be completed),
C<parent_args> (hash, arguments given to C<shell_complete_arg()>), C<args> (hash,
parsed function arguments from C<words>) C<remaining_words> (array, slice of
C<words> after C<cword>), C<meta> (the Rinci function metadata).

Code should return an arrayref of completion, or C<undef> to declare declination,
on which case completion will resume using the standard builtin routine.

A use-case of using this option: XXX.

=item * B<cword> => I<int>

On which word cursor is located (zero-based).

If unset, will be taken from COMPI<LINE and COMP>POINT.

=item * B<extra_completer_args> => I<hash>

Arguments to pass to custom completion routines.

Completion routines will get this from their C<parent_args> argument.

=item * B<meta>* => I<hash>

Rinci function metadata, must be normalized.

=item * B<riap_client> => I<obj>

Optional, to perform complete_arg_val to the server.

When the argument spec in the Rinci metadata contains C<completion> key, this
means there is custom completion code for that argument. However, if retrieved
from a remote server, sometimes the C<completion> key no longer contains the code
(it has been cleansed into a string). Moreover, the completion code needs to run
on the server.

If supplied this argument, C<riap_server_url>, and the C<riap_uri> arguments, the
function will try to request to the server (via Riap request
C<complete_arg_val>). Otherwise, the function will just give up/decline
completing.

=item * B<riap_server_url> => I<str>

Optional, to perform complete_arg_val to the server.

See the C<riap_client> argument.

=item * B<riap_uri> => I<str>

Optional, to perform complete_arg_val to the server.

See the C<riap_client> argument.

=item * B<words> => I<array>

Command-line, broken as words.

If unset, will be taken from COMPI<LINE and COMP>POINT.

=back

Return value:

=for Pod::Coverage ^(.+)$

=head1 BUGS/LIMITATIONS/TODOS

Due to parsing limitation (invokes subshell), can't complete unclosed quotes,
e.g.

 foo "bar <tab>

while shell function can complete this because they are provided C<COMP_WORDS>
and C<COMP_CWORD> by bash.

=head1 SEE ALSO

L<Perinci::CmdLine>

Other shell completion modules on CPAN: L<Getopt::Complete>,
L<Bash::Completion>.

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
