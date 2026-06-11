#!/bin/bash
set -e

echo "Installing PostgreSQL..."
sudo apt-get update
sudo apt-get install -y postgresql postgresql-contrib

echo "Creating demo database and user..."
sudo -u postgres psql -c "CREATE DATABASE demodb;"
sudo -u postgres psql -c "CREATE USER demouser WITH PASSWORD 'demopass';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE demodb TO demouser;"

echo "Creating demo table with sample data..."
sudo -u postgres psql demodb -c "
CREATE TABLE demo_data (
  id SERIAL PRIMARY KEY,
  message TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO demo_data (message) VALUES
  ('Hello from Raspberry Pi!'),
  ('Skupper makes networking easy'),
  ('No egress IP needed!');
"

echo "Granting table privileges..."
sudo -u postgres psql demodb -c "
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO demouser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO demouser;
"

echo "Configuring PostgreSQL to listen on localhost..."
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/g" \
  /etc/postgresql/15/main/postgresql.conf

echo "Adding authentication rule..."
echo "host    demodb          demouser        127.0.0.1/32            scram-sha-256" | \
  sudo tee -a /etc/postgresql/15/main/pg_hba.conf

echo "Restarting PostgreSQL..."
sudo systemctl restart postgresql

echo "Testing connection..."
PGPASSWORD=demopass psql -h 127.0.0.1 -U demouser -d demodb -c "SELECT * FROM demo_data;"

echo "PostgreSQL setup complete!"
