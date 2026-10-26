CREATE TABLE IF NOT EXISTS tickets (
  id uuid PRIMARY KEY,
  title varchar(200) NOT NULL,
  description varchar(2000),
  status varchar(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'resolved')),
  priority varchar(10) NOT NULL DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
