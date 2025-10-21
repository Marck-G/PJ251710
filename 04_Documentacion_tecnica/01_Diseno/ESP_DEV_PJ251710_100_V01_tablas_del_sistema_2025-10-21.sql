-- =====================================================================
-- SISTEMA DE GESTIÓN DOCUMENTAL - CREACIÓN COMPLETA DE BASE DE DATOS
-- Fecha: 2025-10-21
-- Basado en ESP_DEV_PJ251710_001_V00_Sistem_requirements y esquema SQL V01
-- =====================================================================

-- Crear base de datos (si no existe)
-- CREATE DATABASE gestor_documental
--   WITH OWNER = postgres
--   ENCODING = 'UTF8'
--   LC_COLLATE = 'es_ES.UTF-8'
--   LC_CTYPE = 'es_ES.UTF-8'
--   TEMPLATE template0;

-- \c gestor_documental;

-- =====================================================================
-- 1. EXTENSIONES NECESARIAS
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

-- =====================================================================
-- 2. TABLAS BÁSICAS
-- =====================================================================

-- ---------------------------------------------------------------------
-- 2.1. Usuarios (solo referencia, asume autenticación externa)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS usuario (
  id_usuario UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre VARCHAR(100) NOT NULL,
  correo VARCHAR(150) UNIQUE NOT NULL,
  rol VARCHAR(50) NOT NULL,
  activo BOOLEAN DEFAULT TRUE,
  fecha_creacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------
-- 2.2. Tablas de retención documental (TRD)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS serie_documental (
  id_serie UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo VARCHAR(50) UNIQUE NOT NULL,
  nombre VARCHAR(150) NOT NULL,
  descripcion TEXT,
  nivel VARCHAR(50),
  fecha_creacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS trd (
  id_trd UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  id_serie UUID NOT NULL REFERENCES serie_documental(id_serie) ON DELETE CASCADE,
  tipo_documental VARCHAR(100) NOT NULL,
  tiempo_gestion INT NOT NULL,
  tiempo_central INT NOT NULL,
  disposicion_final VARCHAR(50) NOT NULL, -- conservación, eliminación, etc.
  observaciones TEXT,
  fecha_creacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================================
-- 3. DOCUMENTOS Y VERSIONES
-- =====================================================================
CREATE TABLE IF NOT EXISTS documento (
  id_documento UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo_interno VARCHAR(100) UNIQUE,
  titulo VARCHAR(255) NOT NULL,
  descripcion TEXT,
  productor VARCHAR(150),
  id_trd UUID REFERENCES trd(id_trd),
  id_usuario_creador UUID REFERENCES usuario(id_usuario),
  fecha_creacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  estado VARCHAR(50) DEFAULT 'activo',
  nivel_acceso VARCHAR(50) DEFAULT 'publico',
  hash_archivo CHAR(64),                 -- SHA-256
  ruta_archivo TEXT,
  metadatos_json JSONB DEFAULT '{}'::jsonb,  -- ISO 23081
  tsv tsvector                           -- para búsquedas full-text
);

CREATE INDEX IF NOT EXISTS idx_documento_titulo ON documento(titulo);
CREATE INDEX IF NOT EXISTS idx_documento_estado ON documento(estado);
CREATE INDEX IF NOT EXISTS idx_documento_metadatos_json ON documento USING GIN (metadatos_json);

-- Tabla de versiones
CREATE TABLE IF NOT EXISTS documento_version (
  id_documento_version BIGSERIAL PRIMARY KEY,
  id_documento UUID NOT NULL REFERENCES documento(id_documento) ON DELETE CASCADE,
  numero_version INT NOT NULL,
  hash_version CHAR(64) NOT NULL,
  ruta_archivo TEXT NOT NULL,
  fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  id_usuario UUID REFERENCES usuario(id_usuario)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_documento_version_num
  ON documento_version (id_documento, numero_version);

-- =====================================================================
-- 4. METADATOS ADICIONALES (opcional para granularidad)
-- =====================================================================
CREATE TABLE IF NOT EXISTS metadato (
  id_metadato BIGSERIAL PRIMARY KEY,
  id_documento UUID NOT NULL REFERENCES documento(id_documento) ON DELETE CASCADE,
  nombre VARCHAR(100) NOT NULL,
  valor TEXT,
  UNIQUE (id_documento, nombre)
);

-- =====================================================================
-- 5. RELACIONES ENTRE DOCUMENTOS
-- =====================================================================
CREATE TABLE IF NOT EXISTS relacion_documento (
  id_relacion BIGSERIAL PRIMARY KEY,
  id_documento_origen UUID NOT NULL REFERENCES documento(id_documento) ON DELETE CASCADE,
  id_documento_destino UUID NOT NULL REFERENCES documento(id_documento) ON DELETE CASCADE,
  tipo_relacion VARCHAR(50) NOT NULL,
  fecha_creacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================================
-- 6. AUDITORÍA CON ENCADENAMIENTO HASH
-- =====================================================================
CREATE TABLE IF NOT EXISTS auditoria (
  id_auditoria BIGSERIAL PRIMARY KEY,
  id_documento UUID REFERENCES documento(id_documento) ON DELETE SET NULL,
  id_usuario UUID REFERENCES usuario(id_usuario),
  accion VARCHAR(100) NOT NULL,
  detalle TEXT,
  ip_origen VARCHAR(45),
  fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  hash_prev CHAR(64),
  hash_actual CHAR(64)
);

CREATE INDEX IF NOT EXISTS idx_auditoria_iddocumento ON auditoria(id_documento);
CREATE INDEX IF NOT EXISTS idx_auditoria_fecha ON auditoria(fecha);

-- =====================================================================
-- 7. TABLA DE EVENTOS (OUTBOX PATTERN)
-- =====================================================================
CREATE TABLE IF NOT EXISTS outbox (
  id_outbox BIGSERIAL PRIMARY KEY,
  aggregate_type VARCHAR(100) NOT NULL,  -- 'documento', 'auditoria', etc.
  aggregate_id UUID,
  event_type VARCHAR(150) NOT NULL,      -- 'documento.creado', etc.
  payload JSONB NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  processed BOOLEAN DEFAULT FALSE,
  processed_at TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_outbox_processed ON outbox(processed);

-- =====================================================================
-- 8. FUNCIONES Y TRIGGERS
-- =====================================================================

-- ------------------------------------------------------
-- 8.1. TRIGGER FULL-TEXT EN DOCUMENTO
-- ------------------------------------------------------
CREATE OR REPLACE FUNCTION documento_tsv_trigger() RETURNS trigger AS $$
BEGIN
  NEW.tsv :=
    setweight(to_tsvector('spanish', coalesce(NEW.titulo,'')), 'A') ||
    setweight(to_tsvector('spanish', coalesce(NEW.descripcion,'')), 'B') ||
    setweight(to_tsvector('spanish', coalesce(NEW.productor,'')), 'C');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tsvectorupdate
BEFORE INSERT OR UPDATE ON documento
FOR EACH ROW EXECUTE PROCEDURE documento_tsv_trigger();

CREATE INDEX IF NOT EXISTS idx_documento_tsv ON documento USING GIN (tsv);
CREATE INDEX IF NOT EXISTS idx_documento_titulo_trgm ON documento USING GIN (titulo gin_trgm_ops);

-- ------------------------------------------------------
-- 8.2. TRIGGER AUDITORÍA ENCADENADA (HASH)
-- ------------------------------------------------------
CREATE OR REPLACE FUNCTION auditoria_hash_trigger() RETURNS trigger AS $$
DECLARE
  last_hash CHAR(64);
  data TEXT;
BEGIN
  IF NEW.id_documento IS NOT NULL THEN
    PERFORM 1 FROM documento WHERE id_documento = NEW.id_documento FOR UPDATE;
    SELECT hash_actual INTO last_hash
      FROM auditoria
      WHERE id_documento = NEW.id_documento
      ORDER BY fecha DESC, id_auditoria DESC
      LIMIT 1;
  ELSE
    last_hash := NULL;
  END IF;

  NEW.hash_prev := last_hash;

  data := coalesce(NEW.id_documento::text,'') || '|' ||
          coalesce(NEW.id_usuario::text,'') || '|' ||
          coalesce(NEW.accion,'') || '|' ||
          coalesce(NEW.fecha::text,'') || '|' ||
          coalesce(NEW.ip_origen,'') || '|' ||
          coalesce(NEW.detalle,'') || '|' ||
          coalesce(NEW.hash_prev,'');

  NEW.hash_actual := encode(digest(data, 'sha256'), 'hex');

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER auditoria_before_insert
BEFORE INSERT ON auditoria
FOR EACH ROW EXECUTE PROCEDURE auditoria_hash_trigger();

-- ------------------------------------------------------
-- 8.3. TRIGGER AUTOINCREMENTO DE VERSION
-- ------------------------------------------------------
CREATE OR REPLACE FUNCTION documento_version_autoinc() RETURNS trigger AS $$
DECLARE
  maxv INT;
BEGIN
  PERFORM 1 FROM documento WHERE id_documento = NEW.id_documento FOR UPDATE;
  SELECT COALESCE(MAX(numero_version), 0) INTO maxv
    FROM documento_version
    WHERE id_documento = NEW.id_documento;

  IF NEW.numero_version IS NULL OR NEW.numero_version <= 0 THEN
    NEW.numero_version := maxv + 1;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER documento_version_before_insert
BEFORE INSERT ON documento_version
FOR EACH ROW EXECUTE PROCEDURE documento_version_autoinc();

-- ------------------------------------------------------
-- 8.4. TRIGGER OUTBOX (EVENTO DOCUMENTO.CREADO)
-- ------------------------------------------------------
CREATE OR REPLACE FUNCTION documento_outbox_trigger() RETURNS trigger AS $$
DECLARE
  payload JSONB;
BEGIN
  payload := jsonb_build_object(
    'id_documento', NEW.id_documento,
    'titulo', NEW.titulo,
    'id_usuario_creador', NEW.id_usuario_creador,
    'fecha_creacion', NEW.fecha_creacion
  );

  INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload)
  VALUES ('documento', NEW.id_documento, 'documento.creado', payload);

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER documento_after_insert_outbox
AFTER INSERT ON documento
FOR EACH ROW EXECUTE PROCEDURE documento_outbox_trigger();

-- =====================================================================
-- 9. POLÍTICAS DE PARTICIONADO (comentadas para DBA)
-- =====================================================================
-- Ejemplo para particionar auditoría por año:
-- CREATE TABLE auditoria_parent (LIKE auditoria INCLUDING ALL) PARTITION BY RANGE (fecha);
-- CREATE TABLE auditoria_2025 PARTITION OF auditoria_parent
--   FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');

-- =====================================================================
-- 10. USUARIOS Y PERMISOS (seguridad mínima)
-- =====================================================================
-- CREATE ROLE app_user LOGIN PASSWORD '********';
-- GRANT CONNECT ON DATABASE gestor_documental TO app_user;
-- GRANT USAGE, SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;

-- =====================================================================
-- FIN DEL SCRIPT
-- =====================================================================
