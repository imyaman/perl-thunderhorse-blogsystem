package CBlog::Blog;
use v5.40;
use strict;
use warnings;
use Cassandra::Client;

sub new {
    my ($class, %args) = @_;
    # normalize contact_points to an arrayref; accept arrayref, scalar, or comma-separated string
    my $cpts = $args{contact_points};
    if (!defined $cpts) {
        $cpts = ['127.0.0.1'];
    } elsif (ref $cpts ne 'ARRAY') {
        $cpts = [ split /\s*,\s*/, $cpts ];
    }
    my $self = bless {
        contact_points => $cpts,
        keyspace       => $args{keyspace} // 'thunderhorse_blog',
    }, $class;

    my $client = Cassandra::Client->new(contact_points => $self->{contact_points});
    $client->connect;
    $self->{client} = $client;

    $self->_ensure_schema;
    return $self;
}

sub _ensure_schema {
    my ($self) = @_;
    my $ks = $self->{keyspace};

    # create keyspace and table if not present
    $self->{client}->query("CREATE KEYSPACE IF NOT EXISTS $ks WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};");
    $self->{client}->query("CREATE TABLE IF NOT EXISTS $ks.posts (id uuid PRIMARY KEY, title text, body text, tags set<text>, created timestamp);");
}

sub _quote {
    my ($self, $s) = @_;
    return "NULL" unless defined $s;
    $s =~ s/'/''/g;
    return "'$s'";
}

sub create_post {
    my ($self, $title, $body, $tags) = @_;
    $tags //= [];
    my $tags_lit = '{' . join(',', map { $self->_quote($_) } @$tags) . '}';
    my $ks = $self->{keyspace};
    my $cql = "INSERT INTO $ks.posts (id, title, body, tags, created) VALUES (uuid(), " . $self->_quote($title) . ", " . $self->_quote($body) . ", $tags_lit, toTimestamp(now()));";
    $self->{client}->query($cql);
    return 1;
}

sub list_posts {
    my ($self, $limit) = @_;
    $limit ||= 100;
    my $ks = $self->{keyspace};
    my $rows = $self->{client}->query("SELECT id, title, body, tags, created FROM $ks.posts LIMIT $limit;");
    return $rows;
}

sub get_post {
    my ($self, $id) = @_;
    my $ks = $self->{keyspace};
    my $rows = $self->{client}->query("SELECT id, title, body, tags, created FROM $ks.posts WHERE id = $id;");
    return $rows && ref $rows eq 'ARRAY' && @$rows ? $rows->[0] : undef;
}

sub update_post {
    my ($self, $id, $title, $body, $tags) = @_;
    my $ks = $self->{keyspace};
    my @sets;
    push @sets, "title = " . $self->_quote($title) if defined $title;
    push @sets, "body = " . $self->_quote($body) if defined $body;
    if (defined $tags) {
        my $tags_lit = '{' . join(',', map { $self->_quote($_) } @$tags) . '}';
        push @sets, "tags = $tags_lit";
    }
    return 0 unless @sets;
    my $cql = "UPDATE $ks.posts SET " . join(', ', @sets) . " WHERE id = $id;";
    $self->{client}->query($cql);
    return 1;
}

sub delete_post {
    my ($self, $id) = @_;
    my $ks = $self->{keyspace};
    $self->{client}->query("DELETE FROM $ks.posts WHERE id = $id;");
    return 1;
}

1;
