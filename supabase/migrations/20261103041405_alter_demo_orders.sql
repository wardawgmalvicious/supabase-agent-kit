-- An order's status: a column, a constraint on its values, and an index
-- for looking up a customer's orders.
alter table demo.orders add column status text not null default 'pending';

alter table demo.orders
    add constraint orders_status_check
    check (status in ('pending', 'paid', 'shipped', 'cancelled'));

create index orders_customer_id_idx on demo.orders (customer_id);
