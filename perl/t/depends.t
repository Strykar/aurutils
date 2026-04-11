#!/usr/bin/env perl
use strict;
use warnings;
use v5.20;
use Test::More;

# Check if module can be imported
require_ok "AUR::Depends";

AUR::Depends->import(qw(graph prune tsort));

# --- Helper: build $results hash from a list of packages ---
# Each entry: { Name => ..., Version => ..., Provides => [...] }
sub make_results {
    my %results;
    for my $pkg (@_) {
        $results{$pkg->{Name}} = $pkg;
    }
    return %results;
}

# --- Helper: build $pkgdeps like recurse() does ---
# Seeds Self edges for targets, then adds explicit deps.
# $targets: arrayref of target names
# $deps:    hashref  { pkgname => [[$spec, $type], ...] }
sub make_pkgdeps {
    my ($targets, $deps) = @_;
    my %pkgdeps;

    # Seed Self edges the same way recurse() does (line 69-71)
    for my $t (@{$targets}) {
        push @{$pkgdeps{$t}}, [$t, 'Self'];
    }

    # Add explicit dependencies
    for my $name (keys %{$deps}) {
        for my $pair (@{$deps->{$name}}) {
            push @{$pkgdeps{$name}}, $pair;
        }
    }
    return %pkgdeps;
}

# =========================================================
# 1. graph(): single target, no dependencies
# =========================================================
subtest 'graph: single target, no deps' => sub {
    my %results = make_results(
        { Name => 'foo', Version => '1.0-1' },
    );
    my %pkgdeps = make_pkgdeps(['foo'], {});
    my %pkgmap;

    my ($dag, $dag_foreign) = graph(\%results, \%pkgdeps, \%pkgmap, 0, 0);

    # Self edge should exist
    is($dag->{foo}{foo}, 'Self', 'self edge for target foo');
    is(scalar keys %{$dag_foreign}, 0, 'no foreign deps');
};

# =========================================================
# 2. graph(): simple dependency chain  A -> B -> C
# =========================================================
subtest 'graph: linear chain A -> B -> C' => sub {
    my %results = make_results(
        { Name => 'A', Version => '1.0-1' },
        { Name => 'B', Version => '2.0-1' },
        { Name => 'C', Version => '3.0-1' },
    );
    my %pkgdeps = make_pkgdeps(['A'], {
        'A' => [['B', 'Depends']],
        'B' => [['C', 'Depends']],
    });
    my %pkgmap;

    my ($dag, $dag_foreign) = graph(\%results, \%pkgdeps, \%pkgmap, 0, 0);

    is($dag->{A}{A}, 'Self',    'A self edge');
    is($dag->{B}{A}, 'Depends', 'B required by A');
    is($dag->{C}{B}, 'Depends', 'C required by B');
};

# =========================================================
# 3. graph(): empty depends (package with no dependencies)
# =========================================================
subtest 'graph: target with empty depends' => sub {
    my %results = make_results(
        { Name => 'leaf', Version => '0.1-1' },
    );
    my %pkgdeps = make_pkgdeps(['leaf'], {});
    my %pkgmap;

    my ($dag, $dag_foreign) = graph(\%results, \%pkgdeps, \%pkgmap, 0, 0);

    is($dag->{leaf}{leaf}, 'Self', 'self edge exists');
    is(scalar keys %{$dag}, 1, 'only one node in DAG');
};

# =========================================================
# 4. graph(): foreign (non-AUR) dependencies
# =========================================================
subtest 'graph: foreign dependency' => sub {
    my %results = make_results(
        { Name => 'mypkg', Version => '1.0-1' },
    );
    my %pkgdeps = make_pkgdeps(['mypkg'], {
        'mypkg' => [['glibc', 'Depends']],
    });
    my %pkgmap;

    my ($dag, $dag_foreign) = graph(\%results, \%pkgdeps, \%pkgmap, 0, 0);

    is($dag->{mypkg}{mypkg}, 'Self', 'self edge');
    is($dag_foreign->{glibc}{mypkg}, 'Depends', 'glibc in foreign DAG');
    ok(not(defined $dag->{glibc}), 'glibc not in main DAG');
};

# =========================================================
# 5. graph(): provider replaces dependency
# =========================================================
subtest 'graph: provider ($provides=1)' => sub {
    my %results = make_results(
        { Name => 'mypkg',    Version => '1.0-1' },
        { Name => 'libfoo',   Version => '2.0-1' },
    );
    my %pkgdeps = make_pkgdeps(['mypkg'], {
        'mypkg' => [['libfoo', 'Depends']],
    });
    # provider-pkg provides libfoo
    my %pkgmap = ( 'libfoo' => ['provider-pkg', '2.0'] );

    # $provides=1: provider takes precedence
    my ($dag, $dag_foreign) = graph(\%results, \%pkgdeps, \%pkgmap, 0, 1);

    is($dag->{'provider-pkg'}{mypkg}, 'Depends',
        'edge goes through provider-pkg when $provides=1');
};

# =========================================================
# 6. graph(): provider disabled ($provides=0)
# =========================================================
subtest 'graph: provider disabled ($provides=0)' => sub {
    my %results = make_results(
        { Name => 'mypkg',  Version => '1.0-1' },
        { Name => 'libfoo', Version => '2.0-1' },
    );
    my %pkgdeps = make_pkgdeps(['mypkg'], {
        'mypkg' => [['libfoo', 'Depends']],
    });
    my %pkgmap = ( 'libfoo' => ['provider-pkg', '2.0'] );

    # $provides=0: use the package itself
    my ($dag, $dag_foreign) = graph(\%results, \%pkgdeps, \%pkgmap, 0, 0);

    is($dag->{libfoo}{mypkg}, 'Depends',
        'edge goes to libfoo directly when $provides=0');
    ok(not(defined $dag->{'provider-pkg'}),
        'provider-pkg not in DAG when $provides=0');
};

# =========================================================
# 7. graph(): self edge when target has a provider
#    This demonstrates the redirection issue.
#    When $provides=1 and another package provides $target,
#    the self edge is redirected through the provider.
# =========================================================
subtest 'graph: self edge with provider redirection' => sub {
    my %results = make_results(
        { Name => 'foo', Version => '1.0-1' },
        { Name => 'bar', Version => '2.0-1' },
    );
    # foo is a target, so it gets a Self edge [$foo, 'Self']
    my %pkgdeps = make_pkgdeps(['foo'], {
        'bar' => [['foo', 'Depends']],
    });
    # bar provides foo
    my %pkgmap = ( 'foo' => ['bar', '1.0'] );

    my ($dag, $dag_foreign) = graph(\%results, \%pkgdeps, \%pkgmap, 0, 1);

    # The Self edge for foo gets redirected: dag{bar}{foo} = 'Self'
    # instead of the expected dag{foo}{foo} = 'Self'
    is($dag->{bar}{foo}, 'Self',
        'self edge redirected through provider (current behavior)');
};

# =========================================================
# 8. graph(): versioned dependency (verify=1)
# =========================================================
subtest 'graph: versioned dependency passes vercmp' => sub {
    my %results = make_results(
        { Name => 'app',    Version => '1.0-1' },
        { Name => 'libbar', Version => '3.5-1' },
    );
    my %pkgdeps = make_pkgdeps(['app'], {
        'app' => [['libbar>=3.0', 'Depends']],
    });
    my %pkgmap;

    my ($dag, $dag_foreign) = graph(\%results, \%pkgdeps, \%pkgmap, 1, 0);

    is($dag->{libbar}{app}, 'Depends',
        'versioned dep libbar>=3.0 satisfied by 3.5');
};

# =========================================================
# 9. graph(): multiple dependency types
# =========================================================
subtest 'graph: multiple dep types' => sub {
    my %results = make_results(
        { Name => 'pkg',      Version => '1.0-1' },
        { Name => 'libdep',   Version => '1.0-1' },
        { Name => 'buildtool', Version => '2.0-1' },
        { Name => 'checker',  Version => '0.5-1' },
    );
    my %pkgdeps = make_pkgdeps(['pkg'], {
        'pkg' => [
            ['libdep',    'Depends'],
            ['buildtool', 'MakeDepends'],
            ['checker',   'CheckDepends'],
        ],
    });
    my %pkgmap;

    my ($dag, $dag_foreign) = graph(\%results, \%pkgdeps, \%pkgmap, 0, 0);

    is($dag->{libdep}{pkg},    'Depends',      'Depends edge');
    is($dag->{buildtool}{pkg}, 'MakeDepends',  'MakeDepends edge');
    is($dag->{checker}{pkg},   'CheckDepends', 'CheckDepends edge');
};

# =========================================================
# 10. graph(): multiple targets
# =========================================================
subtest 'graph: multiple targets each get self edges' => sub {
    my %results = make_results(
        { Name => 'X', Version => '1.0-1' },
        { Name => 'Y', Version => '1.0-1' },
    );
    my %pkgdeps = make_pkgdeps(['X', 'Y'], {});
    my %pkgmap;

    my ($dag, $dag_foreign) = graph(\%results, \%pkgdeps, \%pkgmap, 0, 0);

    is($dag->{X}{X}, 'Self', 'X self edge');
    is($dag->{Y}{Y}, 'Self', 'Y self edge');
};

# =========================================================
# 11. graph(): dead code proof - line 192 condition
#     Demonstrates that $pkgdeps->{$name} is always an
#     arrayref, never a string, so the `eq` check is dead.
# =========================================================
subtest 'graph: pkgdeps values are always arrayrefs (dead code proof)' => sub {
    my %results = make_results(
        { Name => 'test', Version => '1.0-1' },
    );
    my %pkgdeps = make_pkgdeps(['test'], {});

    # Verify the data structure: pkgdeps{test} is an arrayref
    is(ref($pkgdeps{test}), 'ARRAY',
        'pkgdeps entry is ARRAY ref, not a scalar (confirms #1252)');

    # The dead code does: $pkgdeps->{$name} eq $name
    # This can never be true for an arrayref
    ok($pkgdeps{test} ne 'test',
        'arrayref ne string is always true');
};

# =========================================================
# 12. prune(): remove installed packages
# =========================================================
subtest 'prune: removes installed packages' => sub {
    # Build a DAG: C <- B <- A (Self)
    my %dag = (
        'A' => { 'A' => 'Self' },
        'B' => { 'A' => 'Depends' },
        'C' => { 'B' => 'Depends' },
    );

    my @removed = prune(\%dag, ['C']);

    ok((grep { $_ eq 'C' } @removed), 'C was pruned');
    ok(not(defined $dag{C}), 'C removed from DAG');
    ok(defined $dag{A}, 'A remains in DAG');
    ok(defined $dag{B}, 'B remains in DAG');
};

# =========================================================
# 13. prune(): cascading removal
# =========================================================
subtest 'prune: cascading removal of orphaned deps' => sub {
    # B is only needed by A. If A is installed, B becomes orphaned.
    my %dag = (
        'A' => { 'A' => 'Self' },
        'B' => { 'A' => 'Depends' },
    );

    my @removed = prune(\%dag, ['A']);

    ok((grep { $_ eq 'A' } @removed), 'A was pruned');
    ok((grep { $_ eq 'B' } @removed), 'B was pruned (cascading)');
    is(scalar keys %dag, 0, 'DAG is empty after cascading prune');
};

# =========================================================
# 14. prune(): empty installed list is a no-op
# =========================================================
subtest 'prune: empty installed list' => sub {
    my %dag = (
        'A' => { 'A' => 'Self' },
        'B' => { 'A' => 'Depends' },
    );

    my @removed = prune(\%dag, []);

    is(scalar @removed, 0, 'nothing pruned');
    is(scalar keys %dag, 2, 'DAG unchanged');
};

# =========================================================
# 15. tsort(): simple chain
# =========================================================
subtest 'tsort: linear chain' => sub {
    # Pairs: A->A (self), B->A, C->B
    my @input = ('A', 'A', 'B', 'A', 'C', 'B');
    my @sorted = tsort(0, \@input);

    # C depends on B depends on A, so DFS order is C, B, A
    is($sorted[0], 'C', 'C first (deepest)');
    is($sorted[-1], 'A', 'A last (root)');
};

# =========================================================
# 16. tsort(): self loop only
# =========================================================
subtest 'tsort: self loop only' => sub {
    my @input = ('X', 'X');
    my @sorted = tsort(0, \@input);

    is(scalar @sorted, 1, 'one element');
    is($sorted[0], 'X', 'element is X');
};

# =========================================================
# 17. tsort(): BFS mode
# =========================================================
subtest 'tsort: BFS mode' => sub {
    # Diamond: D depends on B and C, both depend on A
    my @input = ('A', 'A', 'B', 'A', 'C', 'A', 'D', 'B', 'D', 'C');
    my @sorted = tsort(1, \@input);

    is($sorted[0], 'D', 'D first in BFS (only node with no predecessors)');
    is($sorted[-1], 'A', 'A last in BFS (leaf)');
};

done_testing();
# vim: set et sw=4 sts=4 ft=perl:
