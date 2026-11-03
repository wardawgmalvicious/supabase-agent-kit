-- The demo schema and its first tables. A schema outside public is not
-- exposed by the Data API, which keeps the demo contained; row-level
-- security is on anyway, in case the schema is exposed later.
create schema demo;

create table demo.customers (
    id bigint generated always as identity primary key,
    email text not null unique,
    created_at timestamptz not null default now()
);

create table demo.orders (
    id bigint generated always as identity primary key,
    customer_id bigint not null references demo.customers (id),
    total numeric(10, 2) not null,
    created_at timestamptz not null default now()
);

alter table demo.customers enable row level security;
alter table demo.orders enable row level security;
