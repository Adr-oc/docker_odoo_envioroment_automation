#!/bin/bash

# =========================
# Deploy Odoo cross-platform con spinner - MEJORADO
# =========================

# Colores
GREEN=$'\e[1;32m'
YELLOW=$'\e[1;33m'
RED=$'\e[1;31m'
BLUE=$'\e[1;34m'
CYAN=$'\e[1;36m'
BOLD=$'\e[1m'
RESET=$'\e[0m'

# Spinner simple y elegante
show_progress() {
    local pid=$1
    local message=$2
    local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local delay=0.1
    local count=0
    
    echo -n "${BLUE}${message}${RESET} "
    
    while kill -0 "$pid" 2>/dev/null; do
        local pos=$((count % 10))
        local char=${chars:$pos:1}
        
        printf "\r${BLUE}${message}${RESET} ${YELLOW}${char}${RESET}"
        
        sleep $delay
        count=$((count + 1))
    done
    
    # Mostrar completado
    printf "\r${BLUE}${message}${RESET} ${GREEN}✓${RESET}\n"
}

# Función mejorada para instalar .deb con progreso
install_deb_with_progress() {
    local container_name=$1
    local deb_file=$2
    local odoo_version=$3
    
    echo -e "${BLUE}Instalando paquete Odoo ${odoo_version}...${RESET}"
    
    # Ejecutar la instalación en background con output limpio
    docker exec -u root "$container_name" bash -c "
        apt update -qq >/dev/null 2>&1
        apt-get install -f -y >/dev/null 2>&1
        cd /mnt/extra-addons
        dpkg -i odoo_${odoo_version}.deb >/dev/null 2>&1 || {
            apt-get install -f -y >/dev/null 2>&1
        }
        echo 'OK'
    " > /tmp/odoo_install.log 2>&1 & pid=$!
    
    # Mostrar progreso
    show_progress $pid "Instalando Odoo ${odoo_version}.deb"
    wait $pid
    
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✅ Paquete Odoo instalado correctamente${RESET}"
    else
        echo -e "${RED}❌ Error durante la instalación del paquete${RESET}"
        echo -e "${YELLOW}💡 Verificando logs del contenedor...${RESET}"
        docker logs --tail=10 "$container_name"
        return 1
    fi
    
    return 0
}

# Detectar sistema operativo
OS_TYPE=$(uname)

echo -e "${BOLD}${CYAN}=== Despliegue de Odoo con Docker ===${RESET}"

# Pedimos variables al usuario
read -p "${YELLOW}URL del repositorio: ${RESET}" REPO_URL
read -p "${YELLOW}Versión de Odoo (ej. 16, 17, 18): ${RESET}" ODOO_VERSION
read -p "${YELLOW}Nombre de la instancia: ${RESET}" INSTANCE
read -p "${YELLOW}Puerto web (default 8069): ${RESET}" WEB_PORT
read -p "${YELLOW}Puerto PostgreSQL (default 5432): ${RESET}" DB_PORT
WEB_PORT=${WEB_PORT:-8069}
DB_PORT=${DB_PORT:-5432}

# Validar si es Enterprise o Community
read -p "${YELLOW}¿Es una instalación Enterprise? (y/n): ${RESET}" IS_ENTERPRISE
read -p "${YELLOW}¿Activar modo desarrollador? (y/n): ${RESET}" DEV_MODE

# Nombre del repo y carpeta
REPO_NAME=$(basename -s .git "$REPO_URL")
BASE_DIR=~/desarrollo/odoo
ODOO_IMAGES_DIR=~/desarrollo/odoo/odoo_images
REPO_DIR=$BASE_DIR/$REPO_NAME

# Clonar repo si no existe
if [ -d "$REPO_DIR" ]; then
    echo -e "${YELLOW}⚠️  El repositorio '$REPO_NAME' ya existe.${RESET}"
else
    echo -e "${BLUE}Clonando repositorio...${RESET}"
    git clone "$REPO_URL" "$REPO_DIR" & pid=$!
    show_progress $pid "Clonando repositorio"
    wait $pid
fi

# Mostrar modo seleccionado
if [[ "$DEV_MODE" == "y" || "$DEV_MODE" == "Y" ]]; then
    echo -e "${YELLOW}🚀 Modo desarrollador activado${RESET}"
else
    echo -e "${BLUE}📦 Modo producción${RESET}"
fi

# Preparar imagen según el tipo
if [[ "$IS_ENTERPRISE" == "y" || "$IS_ENTERPRISE" == "Y" ]]; then
    ODOO_IMAGE="odoo:${ODOO_VERSION}"
    echo -e "${YELLOW}⚠️ Usando imagen Community. Para Enterprise necesitas construir imagen personalizada${RESET}"
else
    ODOO_IMAGE="odoo:${ODOO_VERSION}"
fi

# Copiar .deb si existe
DEB_FILE="$ODOO_IMAGES_DIR/odoo_${ODOO_VERSION}.deb"
DEB_EXISTS=false

if [ -f "$DEB_FILE" ]; then
    echo -e "${BLUE}Copiando paquete Odoo...${RESET}"
    cp "$DEB_FILE" "$REPO_DIR/" & pid=$!
    show_progress $pid "Copiando paquete Odoo"
    wait $pid
    DEB_EXISTS=true
else
    echo -e "${YELLOW}⚠️ No se encontró $DEB_FILE${RESET}"
fi

# Generar docker-compose.yml mejorado (SIN VERSION OBSOLETA)
echo -e "${BLUE}Generando docker-compose.yml...${RESET}"

# Generar el archivo paso a paso para evitar problemas con variables complejas
cat > "$REPO_DIR/docker-compose.yml" <<EOF
services:
  db_${INSTANCE}:
    image: postgres:13
    container_name: db_${INSTANCE}
    restart: unless-stopped
    environment:
      - POSTGRES_DB=postgres
      - POSTGRES_USER=odoo
      - POSTGRES_PASSWORD=odoo
      - POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C
    ports:
      - "${DB_PORT}:5432"
    volumes:
      - db_data_${INSTANCE}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo"]
      interval: 10s
      timeout: 5s
      retries: 5

  odoo_${INSTANCE}:
    image: ${ODOO_IMAGE}
    container_name: odoo_${INSTANCE}
    depends_on:
      db_${INSTANCE}:
        condition: service_healthy
    ports:
      - "${WEB_PORT}:8069"
    volumes:
      - ./:/mnt/extra-addons
      - odoo_web_data_${INSTANCE}:/var/lib/odoo
      - odoo_filestore_${INSTANCE}:/var/lib/odoo/filestore
EOF

# Agregar volumen del .deb si existe
if [ "$DEB_EXISTS" = true ]; then
    cat >> "$REPO_DIR/docker-compose.yml" <<EOF
      - ./odoo_${ODOO_VERSION}.deb:/mnt/extra-addons/odoo_${ODOO_VERSION}.deb
EOF
fi

# Continuar con environment
cat >> "$REPO_DIR/docker-compose.yml" <<EOF
    environment:
      - HOST=db_${INSTANCE}
      - USER=odoo
      - PASSWORD=odoo
      - DB_MAXCONN=64
EOF

# Agregar comando según el modo
if [[ "$DEV_MODE" == "y" || "$DEV_MODE" == "Y" ]]; then
    cat >> "$REPO_DIR/docker-compose.yml" <<EOF
    command: ["odoo", "--dev=reload,qweb,werkzeug,xml"]
EOF
else
    cat >> "$REPO_DIR/docker-compose.yml" <<EOF
    command: odoo
EOF
fi

# Completar el archivo
cat >> "$REPO_DIR/docker-compose.yml" <<EOF
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8069/web/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

volumes:
  db_data_${INSTANCE}:
    driver: local
  odoo_web_data_${INSTANCE}:
    driver: local
  odoo_filestore_${INSTANCE}:
    driver: local
EOF

# Crear archivo de configuración Odoo
echo -e "${BLUE}Creando configuración de Odoo...${RESET}"
cat > "$REPO_DIR/odoo.conf" <<EOF
[options]
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/var/lib/odoo/addons/${ODOO_VERSION},/mnt/extra-addons
data_dir = /var/lib/odoo
db_host = db_${INSTANCE}
db_port = 5432
db_user = odoo
db_password = odoo
db_maxconn = 64
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = -1
max_cron_threads = 1
workers = 0
log_level = info
log_handler = :INFO
logfile = False
EOF

cd "$REPO_DIR"

# Función para limpiar contenedores existentes
cleanup_containers() {
    echo -e "${BLUE}Limpiando contenedores existentes...${RESET}"
    
    # Detener contenedores del puerto web
    OCCUPIED=$(docker ps --format '{{.Names}} {{.Ports}}' | grep ":${WEB_PORT}->8069" | awk '{print $1}')
    if [ -n "$OCCUPIED" ]; then
        echo -e "${YELLOW}⚠️ Deteniendo contenedores en puerto ${WEB_PORT}:${RESET}"
        echo "$OCCUPIED" | xargs -r docker stop
    fi
    
    # Detener contenedores del puerto DB
    OCCUPIED_DB=$(docker ps --format '{{.Names}} {{.Ports}}' | grep ":${DB_PORT}->5432" | awk '{print $1}')
    if [ -n "$OCCUPIED_DB" ]; then
        echo -e "${YELLOW}⚠️ Deteniendo contenedores en puerto ${DB_PORT}:${RESET}"
        echo "$OCCUPIED_DB" | xargs -r docker stop
    fi
    
    # Limpiar contenedores específicos si existen
    if docker ps -a --format '{{.Names}}' | grep -q "^odoo_${INSTANCE}$"; then
        echo -e "${YELLOW}Removiendo contenedor odoo_${INSTANCE}...${RESET}"
        docker rm -f "odoo_${INSTANCE}" 2>/dev/null || true
    fi
    
    if docker ps -a --format '{{.Names}}' | grep -q "^db_${INSTANCE}$"; then
        echo -e "${YELLOW}Removiendo contenedor db_${INSTANCE}...${RESET}"
        docker rm -f "db_${INSTANCE}" 2>/dev/null || true
    fi
}

cleanup_containers

# Levantar contenedores con barra de progreso (OUTPUT LIMPIO)
echo -e "${BLUE}Levantando contenedores...${RESET}"
docker compose up -d --wait >/dev/null 2>&1 & pid=$!
show_progress $pid "Iniciando servicios"
wait $pid

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Contenedores listos${RESET}"
else
    echo -e "${RED}❌ Error al levantar contenedores${RESET}"
    echo -e "${YELLOW}💡 Mostrando logs...${RESET}"
    docker compose logs
    exit 1
fi

# Función para arreglar permisos de Odoo
fix_odoo_permissions() {
    local container_name=$1
    echo -e "${BLUE}Configurando permisos de Odoo...${RESET}"
    
    docker exec -u root "$container_name" bash -c "
        # Crear directorios si no existen
        mkdir -p /var/lib/odoo/filestore /var/lib/odoo/sessions
        # Cambiar propietario a usuario odoo
        chown -R odoo:odoo /var/lib/odoo
        # Dar permisos completos
        chmod -R 755 /var/lib/odoo
        echo 'Permisos configurados correctamente'
    " >/dev/null 2>&1 & pid=$!
    
    show_progress $pid "Configurando permisos"
    wait $pid
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Permisos configurados correctamente${RESET}"
    else
        echo -e "${YELLOW}⚠️ Advertencia: No se pudieron configurar todos los permisos${RESET}"
    fi
}

# Instalar .deb dentro del contenedor si existe (CON BARRA DE PROGRESO MEJORADA)
if [ "$DEB_EXISTS" = true ]; then
    # Esperar a que el contenedor esté completamente listo
    echo -e "${BLUE}Esperando que el contenedor esté listo...${RESET}"
    sleep 5
    
    # Verificar que el contenedor esté corriendo
    if docker ps --format '{{.Names}}' | grep -q "^odoo_${INSTANCE}$"; then
        install_deb_with_progress "odoo_${INSTANCE}" "./odoo_${ODOO_VERSION}.deb" "$ODOO_VERSION"
        
        if [ $? -eq 0 ]; then
            # Arreglar permisos después de la instalación
            fix_odoo_permissions "odoo_${INSTANCE}"
            
            echo -e "${BLUE}Reiniciando contenedor para aplicar cambios...${RESET}"
            docker restart "odoo_${INSTANCE}" & pid=$!
            show_progress $pid "Reiniciando contenedor"
            wait $pid
        else
            echo -e "${RED}❌ Error en la instalación del .deb${RESET}"
        fi
    else
        echo -e "${RED}❌ El contenedor no está corriendo${RESET}"
    fi
else
    # Esperar a que el contenedor esté listo y arreglar permisos
    echo -e "${BLUE}Esperando que el contenedor esté listo...${RESET}"
    sleep 5
    
    if docker ps --format '{{.Names}}' | grep -q "^odoo_${INSTANCE}$"; then
        fix_odoo_permissions "odoo_${INSTANCE}"
    fi
    
    # Reiniciar contenedor Odoo para evitar problemas de caché/configuración
    echo -e "${BLUE}Reiniciando contenedor...${RESET}"
    docker restart odoo_${INSTANCE} & pid=$!
    show_progress $pid "Reiniciando contenedor"
    wait $pid
fi

# Verificar estado de los servicios
echo -e "${BLUE}Verificando servicios...${RESET}"
sleep 5

DB_STATUS=$(docker exec db_${INSTANCE} pg_isready -U odoo 2>/dev/null && echo "${GREEN}✅ OK${RESET}" || echo "${RED}❌ FAIL${RESET}")
ODOO_STATUS=$(docker exec odoo_${INSTANCE} curl -s -f http://localhost:8069/web/health 2>/dev/null && echo "${GREEN}✅ OK${RESET}" || echo "${YELLOW}⏳ INICIANDO${RESET}")

echo -e "${CYAN}📊 Estado DB: ${RESET}$DB_STATUS"
echo -e "${CYAN}🌐 Estado Odoo: ${RESET}$ODOO_STATUS"

# Solo mostrar logs si Odoo no está OK
if [[ "$ODOO_STATUS" == *"INICIANDO"* ]]; then
    echo -e "${YELLOW}⏳ Esperando a que Odoo termine de iniciar...${RESET}"
    # Esperar hasta 30 segundos a que aparezca el mensaje de HTTP service
    timeout 30s bash -c 'until docker logs odoo_'${INSTANCE}' 2>&1 | grep -q "HTTP service.*running"; do sleep 2; done' 2>/dev/null
    echo -e "${GREEN}✅ Odoo listo${RESET}"
fi

# Abrir navegador
URL="http://localhost:${WEB_PORT}"
echo -e "${GREEN}✅ Instancia '${INSTANCE}' creada.${RESET}"
echo -e "${CYAN}📊 Base de datos: Puerto ${DB_PORT}${RESET}"
echo -e "${CYAN}🌐 Web: ${URL}${RESET}"
echo -e "${CYAN}📁 Directorio: ${REPO_DIR}${RESET}"

if [[ "$OS_TYPE" == "Linux" ]]; then
    xdg-open "$URL" &>/dev/null
elif [[ "$OS_TYPE" == "Darwin" ]]; then
    open "$URL"
elif [[ "$OS_TYPE" == "MINGW"* || "$OS_TYPE" == "CYGWIN"* || "$OS_TYPE" == "MSYS"* ]]; then
    explorer.exe "$URL"
elif [[ -n "$WSL_DISTRO_NAME" ]]; then
    powershell.exe /c start "$URL"
else
    echo -e "${YELLOW}Abrir manualmente: $URL${RESET}"
fi

echo -e "${BOLD}${CYAN}=== Deploy finalizado ===${RESET}"
echo -e "${YELLOW}💡 Comandos útiles:${RESET}"
echo -e "   Ver logs: ${CYAN}docker logs -f odoo_${INSTANCE}${RESET}"
echo -e "   Reiniciar: ${CYAN}docker restart odoo_${INSTANCE}${RESET}"
echo -e "   Parar todo: ${CYAN}cd $REPO_DIR && docker compose down${RESET}"