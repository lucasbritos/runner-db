CREATE DATABASE runner;

\connect runner;

CREATE TABLE IF NOT EXISTS commands (
    id					SERIAL PRIMARY KEY,
    name				varchar(40) not NULL,
    command   			text NOT NULL,
    defaults	json NOT NULL DEFAULT '{}'::json,
    timeout     integer NOT NULL
);

CREATE TABLE checks (
    id                              SERIAL PRIMARY KEY,
    name		                    varchar(40) not NULL,
    cron		                    varchar(40) NOT null,
    active		                    boolean NOT null default true,
    command_id        	            integer references commands(id),
    command_params	                json NOT NULL DEFAULT '{}'::json,
    tags                            jsonb NOT NULL DEFAULT '{}'::jsonb,
    dependency                      jsonb NOT NULL DEFAULT '{}'::jsonb,
    next_check_schedule             timestamp NOT null DEFAULT (now() at time zone 'utc'),
    last_check_status               integer not null default 3,
    last_check_text                 text default 'Never ran.',
    last_check_status_timestamp     timestamp NOT null DEFAULT (now() at time zone 'utc'),
    last_check_status_changed       timestamp NOT null DEFAULT (now() at time zone 'utc')
);


CREATE TABLE subscribers (
    id                              SERIAL PRIMARY KEY,
    name		                    varchar(40) not NULL,
    active		                    boolean NOT null default true,
    command_id        	            integer references commands(id),
    command_params	                json NOT NULL DEFAULT '{}'::json,
    tags                            jsonb NOT NULL DEFAULT '{}'::jsonb,
    event_type                      text[],
    status_to                       integer[],
    dependency_check                 boolean not null default true
);

CREATE INDEX subscriberstags ON subscribers USING gin(tags);

CREATE INDEX checktags ON checks USING gin(tags);

CREATE TABLE status_change_history (
    timestamp       timestamp NOT NULL,
    check_id        integer references checks(id),
    status_from     integer not NULL,
    text            text,
    status_to       integer not NULL,
    is_dependency_ok boolean not NULL
);

CREATE INDEX status_change_history_index ON status_change_history (check_id, timestamp);


CREATE TABLE event_type_map (
    status_from                     integer NOT null,
    status_to		                integer NOT null,
    type		                    text NOT null
);

CREATE INDEX event_type_map_index ON event_type_map (status_from, status_to);

CREATE OR REPLACE FUNCTION on_last_state_change()
  RETURNS trigger AS
$$
declare 
	rec record;
	dependency_check boolean;
	check_tags jsonb;
begin
	select dependency from checks where id = new.id into check_tags;

	SELECT count(*)=0 from 
    (SELECT last_check_status,CASE WHEN check_tags::text = '{}' THEN false ELSE check_tags <@ tags end as match FROM checks) as checks
	where match=true and last_check_status != 0 into dependency_check;
	
	insert into status_change_history(timestamp,check_id,status_from,text,status_to,is_dependency_ok) 
	values((now() at time zone 'utc'),NEW.id,OLD.last_check_status,NEW.last_check_text,NEW.last_check_status,dependency_check)
    returning (select type from event_type_map where status_from = OLD.last_check_status and status_to = NEW.last_check_status) as type,
	timestamp,NEW.name as check_name, NEW.tags as check_tags,status_from,status_to,text, dependency_check as "is_dependency_ok" INTO rec  ;
	
    PERFORM pg_notify('check_status_changed',row_to_json(rec)::text);
	NEW.last_check_status_changed = (now() at time zone 'utc');
	RETURN NEW;
END;
$$
LANGUAGE 'plpgsql';   

CREATE TRIGGER last_check_status_change
    BEFORE UPDATE ON checks
    FOR EACH ROW
    WHEN (OLD.last_check_status IS DISTINCT FROM NEW.last_check_status)
    EXECUTE FUNCTION on_last_state_change();
    
CREATE OR REPLACE FUNCTION on_last_state_update()
  RETURNS trigger AS
$$
declare rec record;
begin
	NEW.last_check_status_timestamp = (now() at time zone 'utc');
	RETURN NEW;
END;
$$
LANGUAGE 'plpgsql';

CREATE TRIGGER last_check_status_update
    BEFORE UPDATE ON checks
    FOR EACH ROW
    EXECUTE FUNCTION on_last_state_update();