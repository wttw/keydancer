package KeyDancer;

use strict;
use Carp;
use Crypt::OpenSSL::RSA;
use Data::Dumper;

sub new {
    my $class = shift;
    my $self = {};
    $self->{SCHEMAVERSION} = 1;
    $self->{DBH} = undef;
    bless ($self, $class);
    return $self;
}

sub connect {
    my $self = shift;
    my $dbh = shift;
    croak "Undefined database handle passed to KeyDancer::connect" unless defined $dbh;
    $self->{DBH} = $dbh;
    $self->{DEFAULT} = $dbh->selectrow_hashref("select * from defaults");
}

sub commit {
    my $self = shift;
    $self->{DBH}->commit;
}

sub get_privatekey {
    my $self = shift;
    my $dom = shift;
    unless($dom =~ /^(?:[a-z0-9-]+\.)+[a-z]+$/i) {
	croak "Invalid domain '$dom' passed to KeyDancer::get_privatekey";
    }
    $dom = lc($dom);

    my $dbh = $self->{DBH};
    my $getpkh = $dbh->prepare('select privkey from customers where dom=?');
    $getpkh->execute($dom);
    my $privatekey;
    while(my ($pk) = $getpkh->fetchrow_array) {
	$privatekey = $pk;
    }
    return $privatekey if defined $privatekey;
    $self->make_customer($dom);
    $dbh->commit;
    $getpkh->execute($dom);
    while(my ($pk) = $getpkh->fetchrow_array) {
	$privatekey = $pk;
    }
    return $privatekey;
}

sub get_selector {
    my $self = shift;
    my $dom = shift;
    unless($dom =~ /^(?:[a-z0-9-]+\.)+[a-z]+$/i) {
	croak "Invalid domain '$dom' passed to KeyDancer::get_privatekey";
    }
    $dom = lc($dom);

    my $dbh = $self->{DBH};
    my $getselh = $dbh->prepare('select selector1, selector2 from customers where dom=?');
    $getselh->execute($dom);
    my $selector;
    while(my ($s1, $s2) = $getselh->fetchrow_array) {
	$selector = "$s2.$s1";
    }
    return $selector if defined $selector;
    $self->make_customer($dom);
    $dbh->commit;
    $getselh->execute($dom);
    while(my ($s1, $s2) = $getselh->fetchrow_array) {
	$selector = "$s2.$s1";
    }
    return $selector;
}

sub make_customer {
    my $self = shift;
    my $dom = shift;
    unless($dom =~ /^(?:[a-z0-9-]+\.)+[a-z]+$/i) {
	croak "Invalid domain '$dom' passed to KeyDancer::make_customer";
    }
    $dom = lc($dom);

    my $dbh = $self->{DBH};
    my ($cnt) = $dbh->selectrow_array("select count(*) from customers where dom=?", {}, $dom);
    if($cnt) {
	carp "Trying to create customer '$dom' that already exists";
    } else {
	$dbh->do(qq{insert into customers
		           (dom, selector1, cnamebase, selector2, 
                            privkey, pubkey, privexpires, publifetime, privlifetime, keybits)
                  values (?, ?, ?, '0', null, null, now() + ?, ?, ?, ?)}, {},
		 $dom, $self->{DEFAULT}->{selector1}, $self->{DEFAULT}->{cnamebase},
		 $self->{DEFAULT}->{privlifetime}, $self->{DEFAULT}->{publifetime},
		 $self->{DEFAULT}->{privlifetime}, $self->{DEFAULT}->{keybits});
    }
    $self->rekey_customer($dom);
}

sub rekey_customer {
    my $self = shift;
    my $dom = shift;
    my $dbh = $self->{DBH};
    my $ref = $dbh->selectrow_arrayref("select selector1, cnamebase, selector2, publifetime, privlifetime, keybits from customers where dom=?", {}, $dom);
    unless(defined $ref) {
	croak "Attempt to rekey non-existent customer '$dom' in KeyDancer::rekey_customer";
    }
    my ($sel1, $cnamebase, $sel2, $publ, $privl, $keybits) = @{$ref};
    
    # Set existing public keys to expire after publifetime
    $dbh->do("update records set pubexpires = least(coalesce(pubexpires, 'infinity'), now() + ?) where name=? and type='TXT'", {}, $publ, "${sel2}.${sel1}._domainkey.${dom}");
    $dbh->do("update records set pubexpires = least(coalesce(pubexpires, 'infinity'), now() + ?) where name=? and type='TXT'", {}, $publ, "${sel2}.${dom}.${cnamebase}");

    # Create new keys
    my $rsa = Crypt::OpenSSL::RSA->generate_key($keybits);
    my $privkey = $rsa->get_private_key_string();
    my $pubkey = $rsa->get_public_key_x509_string();
    my $pubstring = $self->key_to_txt($pubkey);
    
    my $getdomh = $dbh->prepare("select id from domains where name=?");

    # Create CNAME target zone, if needed
    $getdomh->execute($cnamebase);
    my $cnamedomid;
    while(my ($id) = $getdomh->fetchrow_array) {
	$cnamedomid = $id;
    }
    unless(defined $cnamedomid) {
	$dbh->do("insert into domains (name, type) values (?, 'NATIVE')", {}, $cnamebase);
	$getdomh->execute($cnamebase);
	while(my ($id) = $getdomh->fetchrow_array) {
	    $cnamedomid = $id;
	}
	croak "Failed to create zone $cnamebase" unless defined $cnamedomid;
    }


    # Create main target zone, if needed
    my $maindomid;
    my $mainbase = "${sel1}._domainkey.${dom}";
    $getdomh->execute($mainbase);
    while(my ($id) = $getdomh->fetchrow_array) {
	$maindomid = $id;
    }
    unless(defined $maindomid) {
	$dbh->do("insert into domains (name, type) values (?, 'NATIVE')", {}, $mainbase);
	$getdomh->execute($mainbase);
	while(my ($id) = $getdomh->fetchrow_array) {
	    $maindomid = $id;
	}
	croak "Failed to create zone $mainbase" unless defined $maindomid;
    }

    $sel2++;
    
    # Create new TXT records
    
    $dbh->do(qq{insert into records (domain_id, name, type, content, ttl, pubexpires)
                            values (?, ?, 'TXT', ?, ?, now() + ? + ?)}, {},
	     $cnamedomid, "${sel2}.${dom}.${cnamebase}", $pubstring, $self->{DEFAULT}->{ttl}, $publ, $privl);

    $dbh->do(qq{insert into records (domain_id, name, type, content, ttl, pubexpires)
                            values (?, ?, 'TXT', ?, ?, now() + ? + ?)}, {},
	     $maindomid, "${sel2}.${mainbase}", $pubstring, $self->{DEFAULT}->{ttl}, $publ, $privl);

    # and finally, update the customer record
    $dbh->do(qq{update customers set selector2=?, privkey=?, pubkey=?, privexpires= now() + ?
                               where dom=?}, {}, $sel2, $privkey, $pubkey, $privl, $dom);

}

sub maintain_keys {
    my $self = shift;
    my $dbh = $self->{DBH};

    # Rotate any expired private keys
    my $doms = $dbh->selectcol_arrayref("select dom from customers where privexpires < current_timestamp");
    foreach my $d (@$doms) {
	$self->rekey_customer($d);
    }
    my ($nextexpiry) = $dbh->selectrow_array("select extract(epoch from privexpires - current_timestamp) from customers order by privexpires asc limit 1");
    
    # Purge out any expired public keys
    $dbh->do("delete from records where pubexpires < current_timestamp");

    my ($nextnudge) = $dbh->selectrow_array("select extract(epoch from pubexpires - current_timestamp) from records order by pubexpires asc limit 1");


    # Adjust TTLs on soon to expire public keys
    # We don't reduce TTLs gradually, rather pull them down to 60 seconds.
    # This reduces replication overhead, and shouldn't matter as we're not expecting any
    # queries for them at this point
    $dbh->do("update records set ttl = 7200 where ttl > 7200 and immutable_timestamptz_add(pubexpires, ttl) > current_timestamp - interval '7200 seconds'");
    $dbh->do("update records set ttl = 60 where ttl > 60 and immutable_timestamptz_add(pubexpires, ttl) > current_timestamp - interval '60 seconds'");

    return min($nextnudge, $nextexpiry);
}

sub replicate_data {
    
}

sub key_to_txt {
    my $self = shift;
    my $pubkey = shift;
    my @keylist = split(/\n/, $pubkey);
    shift @keylist;
    pop @keylist;
    return 'v=DKIM1;t=s;n=core;p=' . join('', @keylist);
}

1;
