drop table supermasters;
drop table records;
drop table customers;
drop table domains;
drop table nameservers;
drop table defaults;
drop table changes;
drop table schema_version;

begin;

create table schema_version (
  version integer not null
);
create unique index schema_version_one_row on schema_version((1));

create table changes (
  stamp serial primary key,
  id integer not null,
  tab text not null
);

create table defaults (
  publifetime interval not null,
  privlifetime interval not null,
  selector1 text not null,
  cnamebase text not null,
  webhost text not null,
  ttl integer not null,
  keybits integer not null
);
create unique index defaults_one_row on defaults((1));

create table nameservers (
  id serial primary key,
  hostname text not null,
  dsn text,
  username text,
  password text
);

-- For powerdns
create table domains (
  id serial primary key,
  name text unique not null,
  master text default null,
  last_check int default null,
  type text not null,
  notified_serial int default null,
  account text default null
);

create or replace function note_change() returns trigger as $$
  begin
  notify replication_change;
  if TG_OP = 'UPDATE' then
    insert into changes (id, tab) values (NEW.id, TG_TABLE_NAME);
    if NEW.id != OLD.id then
      insert into changes (id, tab) values (OLD.id, TG_TABLE_NAME);
    end if;
  end if;
  if TG_OP = 'INSERT' then
    insert into changes (id, tab) values (NEW.id, TG_TABLE_NAME);
  end if;
  if TG_OP = 'DELETE' then
    insert into changes (id, tab) values (OLD.id, TG_TABLE_NAME);
  end if;
  return null;
  end;
$$ language plpgsql;

create trigger domains_change after insert or update or delete on domains for each row execute procedure note_change();

-- For keydancer
create table customers (
  dom text primary key, -- d=
  selector1 text not null,
  cnamebase text not null,
  selector2 text not null,
  privkey text,
  pubkey text,
  privexpires timestamptz,
  publifetime interval not null,
  privlifetime interval not null,
  keybits integer not null,
  status text not null default 'unchecked' check (status ~ 'ok|error|warn|unchecked'),
  lastcheck timestamptz,
  statusmessage text,
  constraint valid_domain check (dom ~ E'([a-z0-9-]+\\.)+[a-z]')
);

create or replace function customers_change() returns trigger as $$
  begin
    notify customers_change;
    return null;
  end;
$$ language plpgsql;

create trigger customers_change after insert or update or delete on customers for each statement execute procedure customers_change();

-- For powerdns
create table records (
  id serial primary key,
  domain_id int default null references domains(id) on delete cascade,
  name text default null,
  type text default null,
  content text default null,
  ttl int default null,
  prio int default null,
  change_date int default null,
-- for keydancer
  pubexpires timestamptz
);

create or replace function immutable_timestamptz_add(timestamptz, integer) returns timestamptz as $$
  select $1 + $2 * interval '1 second';
$$ language sql strict immutable;

create index records_expire_idx on records(immutable_timestamptz_add(pubexpires, ttl));

create trigger records_change after insert or update or delete on records for each row execute procedure note_change();


CREATE INDEX rec_name_index ON records(name);
CREATE INDEX nametype_index ON records(name,type);
CREATE INDEX domain_id ON records(domain_id);
CREATE INDEX records_expires ON records(pubexpires);

create table supermasters (
	  ip VARCHAR(25) NOT NULL, 
	  nameserver VARCHAR(255) NOT NULL, 
	  account VARCHAR(40) DEFAULT NULL
);



insert into schema_version (version) values (1);

commit;