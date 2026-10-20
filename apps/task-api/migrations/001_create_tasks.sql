CREATE TABLE IF NOT EXISTS tasks (
  id uuid PRIMARY KEY,
  title varchar(200) NOT NULL,
  description varchar(1000),
  completed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
