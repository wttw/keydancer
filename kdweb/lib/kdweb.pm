package kdweb;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use Data::Dumper;
use KeyDancer;

our $VERSION = '0.1';

get '/' => sub {
    template 'index', {tab => 'home'};
};

get '/domain/list/:prefix' => sub {
    my $prefix = params->{prefix};
    $prefix =~ s/[^0-9a-z-]//g;
    my $doms = database->selectall_arrayref(
	"select dom, status from customers where dom like '$prefix%' order by dom"
	);
    my $keys = database->selectcol_arrayref(
	'select substring(dom for 1) from customers group by 1 order by 1'
	);
    template 'dom', {tab => 'dom', domains => $doms, keys => $keys};
};

get '/domain/list' => sub {
    my $doms = database->selectall_arrayref(
	'select dom, status from customers order by dom limit 31'
	);
    if(@$doms < 31) {
	print STDERR Dumper($doms), "\n";
	template 'dom', {tab => 'dom', domains => $doms};
    } else {
	my $keys = database->selectcol_arrayref(
	    'select substring(dom for 1) from customers group by 1 order by 1'
	    );
	template 'dom', {tab => 'dom', keys => $keys};
    }
};

post '/domain/add' => sub {
    my $domain = lc(params->{domain});
    $domain =~ s/^\s+//g;
    $domain =~ s/\s+$//g;
    unless($domain =~ /^(?:[a-z0-9-]+\.)+[a-z]+$/) {
	template 'error', { error => "'$domain' doesn't look like a valid d= value" };
    } else {
	my $kd = KeyDancer->new;
	$kd->connect(database);
	$kd->make_customer($domain);
	$kd->commit;
	redirect "/domain/view/$domain";
    }
};

get '/domain/view/:dom' => sub {
    my $domain = lc(params->{dom});
    unless($domain =~ /^(?:[a-z0-9-]+\.)+[a-z]+$/) {
	template 'error', { error => "'$domain' doesn't look like a valid d= value" };
    } else {
	my $getdomh = database->prepare(
	    'select * from customers where dom=?'
	    );
	$getdomh->execute($domain);
	my $dom;
	while(my $d = $getdomh->fetchrow_hashref) {
	    $dom = $d;
	}
	unless(defined $dom) {
	    template 'error', { error => "I didn't find any entry with '$dom' as it's d= value" };
	} else {
	    my $ns = database->selectcol_arrayref('select hostname from nameservers order by hostname');
	    if(defined $dom->{pubkey}) {
		my $kd = KeyDancer->new;
		$dom->{txt} = $kd->key_to_txt($dom->{pubkey});
		$dom->{txtwrap} = join('<br />', unpack('(A60)*', $dom->{txt}));
	    }
	    template 'domview', { d => $dom, nameservers => $ns };
	}
    }
};

get '/configure' => sub {
    my $dbh = database;
    my $def = $dbh->selectrow_hashref('select * from defaults');
    my $ns = $dbh->selectall_arrayref("select id, hostname, coalesce(dsn, '(none)'), coalesce(username, '(none)') from nameservers");
    my $db = { driver => $dbh->{Driver}->{Name},
	       name => $dbh->{Name},
	       user => $dbh->{Username} };
    template 'config', {tab => 'config', defaults => $def, nameservers => $ns, db => $db };
    
};

post '/configure/update' => sub {
    my $dbh = database;
    my $sth = $dbh->prepare("select * from defaults");
    $sth->execute();
    my @par;
    my @colname;

    for(my $i = 1; $i <= $sth->{NUM_OF_FIELDS}; $i++) {
	my $name = $sth->{NAME}->[$i-1];
	if(exists params->{$name}) {
	    push @par, params->{$name};
	    push @colname, "$name=?";
	}

    }
    $dbh->do("update defaults set " . join(',', @colname), {}, @par);
    $dbh->commit;
    redirect '/configure';
};

get '/configure/editns/:id' => sub {
    my $dbh = database;
    my $ns = $dbh->selectrow_hashref('select * from nameservers where id=?', {}, params->{id});
    template 'configns', { ns => $ns };
};

get '/configure/addns' => sub {
    template 'addns', {};
};

post '/configure/updatens' => sub {
    if(params->{hostname} !~ /^(?:[a-z0-9-]+\.)+[a-z]+$/) {
	template 'error', { error => "'" . params->{hostname} . "' doesn't look like a valid hostname" };
	return;
    }
    if(params->{dsn} ne '' || params->{username} ne '' || params->{password} ne '') {
	my $nsdbh = DBI->connect(params->{dsn}, params->{username}, params->{password});
	if(! defined $nsdbh) {
	    template 'error', { error => "Failed to connect to remote database" };
	    return;
	}
	my $table;
	eval {
	    $table = 'domains';
	    $nsdbh->selectrow_array("select id, name, type from $table limit 1");
	    $table = 'records';
	    $nsdbh->selectrow_array("select id, domain_id, name, type, content, ttl from $table limit 1");
	};
	if($@) {
	    template 'error', { error => "Table $table is missing or malformed on remote database: " . $nsdbh->errstr };
	    $nsdbh->disconnect;
	    return;
	}
	$nsdbh->disconnect;
    }
    my $dsn = params->{dsn};
    undef $dsn if $dsn eq '';
    my $username = params->{username};
    undef $username if $username eq '';
    my $password = params->{password};
    
    my $dbh = database;
    if(params->{id} eq 'new') {
	# Adding
	$dbh->do("insert into nameservers {hostname, dsn, username, password) values (?, ?, ?, ?)", {},
	    params->{hostname}, $dsn, $username, $password);
    } else {
	# Updating
	$dbh->do("update nameservers set hostname=?, dsn=?, username=?, password=? where id=?", {},
		 params->{hostname}, $dsn, $username, $password, params->{id});
    }
    $dbh->commit;
    redirect '/configure';
};

get '/help' => sub {
    template 'help', {tab => 'help'};
};

before_template sub {
    my $tokens = shift;
    $tokens->{uri_base} = request->base;
};

true;
