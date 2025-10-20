CREATE TABLE serie_documental (
    id_serie SERIAL PRIMARY KEY,
    codigo VARCHAR(50) UNIQUE NOT NULL,
    nombre VARCHAR(150) NOT NULL,
    descripcion TEXT,
    id_serie_padre INT REFERENCES serie_documental(id_serie)
);

CREATE TABLE trd (
    id_trd SERIAL PRIMARY KEY,
    id_serie INT NOT NULL REFERENCES serie_documental(id_serie),
    tiempo_retencion_gestion INT NOT NULL,
    tiempo_retencion_central INT NOT NULL,
    disposicion_final VARCHAR(50) CHECK (disposicion_final IN ('Conservación permanente','Eliminación','Selección')),
    fecha_aprobacion DATE NOT NULL
);

CREATE TABLE documento (
    id_documento UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    titulo VARCHAR(255) NOT NULL,
    descripcion TEXT,
    productor VARCHAR(150),
    fecha_creacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    formato VARCHAR(20),
    estado VARCHAR(50) CHECK (estado IN ('Borrador','Vigente','Archivado')),
    nivel_acceso VARCHAR(50) CHECK (nivel_acceso IN ('Público','Interno','Confidencial')),
    ruta_archivo TEXT NOT NULL,
    id_serie INT REFERENCES serie_documental(id_serie),
    id_trd INT REFERENCES trd(id_trd),
    id_usuario_creador UUID NOT NULL,  -- viene del microservicio de usuarios
    hash_integridad CHAR(64) NOT NULL, -- SHA256
    firmado BOOLEAN DEFAULT FALSE,
    fecha_ultima_modificacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_documento_hash ON documento(hash_integridad);
CREATE INDEX idx_documento_estado ON documento(estado);

CREATE TABLE documento_version (
    id_version SERIAL PRIMARY KEY,
    id_documento UUID NOT NULL REFERENCES documento(id_documento) ON DELETE CASCADE,
    numero_version INT NOT NULL,
    fecha_version TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id_usuario UUID NOT NULL,  -- del microservicio de usuarios
    comentario TEXT,
    ruta_archivo TEXT,
    hash_integridad CHAR(64) NOT NULL,
    UNIQUE (id_documento, numero_version)
);

CREATE TABLE metadato (
    id_metadato SERIAL PRIMARY KEY,
    id_documento UUID NOT NULL REFERENCES documento(id_documento) ON DELETE CASCADE,
    nombre VARCHAR(100) NOT NULL,
    valor TEXT,
    tipo_dato VARCHAR(50),
    obligatorio BOOLEAN DEFAULT FALSE
);

CREATE INDEX idx_metadato_nombre ON metadato(nombre);

CREATE TABLE relacion_documento (
    id_relacion SERIAL PRIMARY KEY,
    id_documento_origen UUID REFERENCES documento(id_documento) ON DELETE CASCADE,
    id_documento_destino UUID REFERENCES documento(id_documento) ON DELETE CASCADE,
    tipo_relacion VARCHAR(50) -- Ejemplo: 'Versión', 'Anexo', 'Expediente'
);

CREATE TABLE auditoria (
    id_auditoria BIGSERIAL PRIMARY KEY,
    id_documento UUID REFERENCES documento(id_documento),
    id_usuario UUID NOT NULL,   -- referencia al microservicio de usuarios
    accion VARCHAR(50) NOT NULL, -- crear, leer, modificar, eliminar, firmar, etc.
    fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ip_origen VARCHAR(45),
    detalle TEXT,
    hash_prev CHAR(64), -- hash anterior (encadenamiento)
    hash_actual CHAR(64) NOT NULL
);

CREATE INDEX idx_auditoria_accion ON auditoria(accion);
CREATE INDEX idx_auditoria_usuario ON auditoria(id_usuario);

CREATE TABLE politica_gestion (
    id_politica SERIAL PRIMARY KEY,
    nombre VARCHAR(150) NOT NULL,
    descripcion TEXT,
    area_aplicacion VARCHAR(100),
    fecha_vigencia DATE,
    responsable UUID, -- id de usuario (microservicio)
    version INT DEFAULT 1,
    estado VARCHAR(20) CHECK (estado IN ('Vigente','Revisada','Obsoleta')) DEFAULT 'Vigente'
);
-- Opcional

CREATE TABLE evento (
    id_evento UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tipo_evento VARCHAR(100) NOT NULL,      -- ejemplo: "usuario.creado", "documento.subido"
    origen VARCHAR(100) NOT NULL,           -- microservicio emisor
    destino VARCHAR(100) NOT NULL,          -- microservicio receptor
    payload JSONB NOT NULL,                 -- cuerpo del mensaje
    fecha_emision TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    procesado BOOLEAN DEFAULT FALSE,
    fecha_procesado TIMESTAMP
);

CREATE INDEX idx_evento_tipo ON evento(tipo_evento);
