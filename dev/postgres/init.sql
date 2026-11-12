-- Synapse and MAS each keep a database of their own. Synapse refuses one that does not collate as C.
CREATE DATABASE synapse ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
CREATE DATABASE mas;
