use v5.40;
use lib 'lib';
package CBlog;
use Mooish::Base;
extends 'Thunderhorse::App';
use CBlog::Blog;

sub build ($self)
{
    # basic route
    $self->router->add('/hello/:name', { to => 'greet' });

    # blog routes (prototype)
    $self->router->add('/login',        { to => 'login' });
    $self->router->add('/logout',       { to => 'logout' });
    $self->router->add('/posts',        { to => 'posts_index' });
    $self->router->add('/posts/new',    { to => 'post_new' });
    $self->router->add('/posts/create', { to => 'post_create' });
    $self->router->add('/posts/:id',    { to => 'post_show' });
    $self->router->add('/sse_sample_page',            { to => 'sse_page' });
    $self->router->add('/api/sse_sample_stream',     { to => 'sse_stream' });

    # API routes under /api
    $self->router->add('/api/posts',        { to => 'api_posts_index' });
    $self->router->add('/api/posts/:id',    { to => 'api_post_show' });
    $self->router->add('/api/posts/create', { to => 'api_post_create' });

    # initialize Cassandra-backed blog and attach to the app
    my $config;
    if (eval { require YAML::XS; 1 }) {
        $config = YAML::XS::LoadFile('config.yml');
    }
    $config //= {};
    my $cpts = $config->{cassandra}{contact_points} // [];
    my $keyspace = $config->{cassandra}{keyspace} // 'thunderhorse_blog';
    my $blog;
    if ($cpts && @$cpts) {
        # attempt to connect but don't die the whole app on failure
        eval {
            $blog = CBlog::Blog->new(
                contact_points => $cpts,
                keyspace        => $keyspace,
            );
            1;
        } or do {
            warn "Warning: failed to initialize Cassandra-backed blog: $@";
            $blog = undef;
        };
    } else {
        warn "Note: no Cassandra contact_points configured; running without Cassandra backend.";
    }
    $self->{blog} = $blog;

    # in-memory posts store for prototype
    $self->{posts} //= [
        { id => 1, title => "Welcome", body => "This is the first post.", author => "admin" },
    ];
}

sub greet ($self, $ctx, $name)
{
    return "Hello, $name!";
}

sub login ($self, $ctx)
{
    return q{
        <h1>Login</h1>
        <p>Prototype login page. POST handling and session management not implemented yet.</p>
        <form action="/login" method="post">
            <label>Username: <input name="username"></label><br>
            <label>Password: <input name="password" type="password"></label><br>
            <button type="submit">Login</button>
        </form>
    };
}

sub logout ($self, $ctx)
{
    return "<p>Logged out (prototype).</p>";
}

sub posts_index ($self, $ctx)
{
    my $html = "<h1>Posts</h1><ul>";
    for my $p (@{$self->{posts} // []}) {
        $html .= sprintf('<li><a href="/posts/%d">%s</a> by %s</li>', $p->{id}, $p->{title}, $p->{author});
    }
    $html .= "</ul><p><a href=\"/posts/new\">New post</a></p>";
    return $html;
}

sub post_show ($self, $ctx, $id)
{
    my ($post) = grep { $_->{id} == $id } @{$self->{posts} // []};
    return "<h1>Post not found</h1>" unless $post;
    return sprintf('<h1>%s</h1><p>%s</p><p><em>by %s</em></p>', $post->{title}, $post->{body}, $post->{author});
}

sub post_new ($self, $ctx)
{
    return q{
        <h1>New Post</h1>
        <p>Prototype form (submits GET to /posts/create). Authentication required to write posts not implemented yet.</p>
        <form action="/posts/create" method="get">
            <label>Title: <input name="title"></label><br>
            <label>Body: <textarea name="body"></textarea></label><br>
            <label>Author: <input name="author"></label><br>
            <button type="submit">Create</button>
        </form>
    };
}

sub post_create ($self, $ctx)
{
    # Try to obtain params from $ctx if available, otherwise parse from environment
    my ($title, $body, $author) = ('(no title)', '(no body)', 'anonymous');

    if (eval { $ctx->req->query_params }) {
        my $qp = $ctx->req->query_params;
        $title  = $qp->get('title') // $title;
        $body   = $qp->get('body')  // $body;
        $author = $qp->get('author')// $author;
    } elsif (eval { $ctx->req->json }) {
        my $json = $ctx->req->json;
        $title  = $json->{title}  // $title;
        $body   = $json->{body}   // $body;
        $author = $json->{author} // $author;
    } else {
        # Fallback: try CGI-like env
        use CGI;
        my $q = CGI->new;
        $title  = $q->param('title') // $title;
        $body   = $q->param('body') // $body;
        $author = $q->param('author') // $author;
    }

    my $id = 1 + (scalar @{$self->{posts} // []});
    push @{$self->{posts}}, { id => $id, title => $title, body => $body, author => $author };
    return sprintf('<p>Post created: <a href="/posts/%d">%s</a></p>', $id, $title);
}

sub sse_page ($self, $ctx)
{
    return q{
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>SSE Demo</title>
        </head>
        <body>
            <h1>Server-Sent Events demo</h1>
            <div id="messages"></div>
            <script>
                const out = document.getElementById('messages');
                const es = new EventSource('/api/sse_sample_stream');
                es.onmessage = function(e) {
                    const p = document.createElement('p');
                    p.textContent = 'Ping: ' + e.data;
                    out.appendChild(p);
                };
                es.onerror = function(e) {
                    const p = document.createElement('p');
                    p.textContent = 'EventSource error';
                    out.appendChild(p);
                    es.close();
                };
            </script>
        </body>
        </html>
    };
}

sub sse_stream ($self, $ctx)
{
    # Use Thunderhorse::SSE API when available
    if ($ctx->has_sse) {
        my $sse = $ctx->sse;
        # keep the connection alive and send every 3 seconds
        return $sse->every(3, sub {
            my $send = sub {
                my $time = scalar localtime;
                $sse->send_text($time);
            };
            return $send->();
        });
    }

    # Fallback: set correct content type and return a single event
    if (eval { $ctx->res->content_type('text/event-stream') }) {
        $ctx->res->content_type('text/event-stream');
    }
    return "data: " . (scalar localtime) . "\n\n";
}

# API handlers (JSON)
sub api_posts_index ($self, $ctx)
{
    use JSON::XS;
    return JSON::XS->new->utf8->encode($self->{posts} // []);
}

sub api_post_show ($self, $ctx, $id)
{
    use JSON::XS;
    my ($post) = grep { $_->{id} == $id } @{$self->{posts} // []};
    return JSON::XS->new->utf8->encode({ error => 'not_found' }) unless $post;
    return JSON::XS->new->utf8->encode($post);
}

sub api_post_create ($self, $ctx)
{
    # Accept JSON body preferred
    my ($title, $body, $author) = ('(no title)', '(no body)', 'anonymous');
    if (eval { $ctx->req->json }) {
        my $json = $ctx->req->json;
        $title  = $json->{title}  // $title;
        $body   = $json->{body}   // $body;
        $author = $json->{author} // $author;
    } elsif (eval { $ctx->req->query_params }) {
        my $qp = $ctx->req->query_params;
        $title  = $qp->get('title')  // $title;
        $body   = $qp->get('body')   // $body;
        $author = $qp->get('author') // $author;
    }
    my $id = 1 + (scalar @{$self->{posts} // []});
    push @{$self->{posts}}, { id => $id, title => $title, body => $body, author => $author };
    use JSON::XS;
    return JSON::XS->new->utf8->encode({ id => $id });
}

CBlog->new->run;
