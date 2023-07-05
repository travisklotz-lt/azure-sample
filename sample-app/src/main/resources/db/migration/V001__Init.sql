create schema sample_app;

create table sample_app.widgets (
    id bigserial not null primary key,
    operation text not null
);