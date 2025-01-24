#!/bin/bash

# Força o uso do ponto como separador decimal
export LC_NUMERIC=C  
# Define o terminal com suporte a 256 cores
export TERM=xterm-256color  
# Ajusta o número de colunas do terminal dinamicamente com base no tamanho atual
export COLUMNS=$(tput cols)

# Definição das cores hexadecimais exatas
FILENAMELABEL="\033[38;2;180;255;220m"    # #B4FFDC
FILENAME="\033[1;38;2;0;255;155m"         # #00FF9B (bold)
BEAM="\033[38;2;64;0;255m"                # #4000FF
PERCENTAGE="\033[38;2;226;217;255m"       # #E2D9FF
ETALABEL="\033[38;2;255;180;150m"         # #FFB496
ETA="\033[1;38;2;255;55;0m"               # #FF3700 (bold)
PROMPT="\033[1;38;2;255;230;0m"           # #FFE600 (bold)
ERROR="\033[1;38;2;255;0;0m"              # #FF0000 (bold)
WARNING="\033[1;38;2;255;165;0m"          # #FFA500 (bold)
RECORDING="\033[1;38;2;255;55;0m"         # #FF3700 (bold)
RESET="\033[0m"

# Caracteres da barra de progresso
CHAR_FILLED="▓"
CHAR_EMPTY="░"

# Adiciona variável para controlar o estado do indicador piscante
RECORDING_DOT="●"
recording_dot_visible=true

# Função atualizada para calcular duração total de múltiplos inputs
calculate_total_duration() {
    local total_duration=0
    local is_input_next=false
    local is_concat=false
    local concat_file=""
    local args=("$@")
    local temp_inputs=$(mktemp)
    local audio_duration=0
    local is_loop_image=false
    
    # Primeiro verifica se há imagem com loop
    for ((i=0; i<${#args[@]}; i++)); do
        if [ "${args[i]}" = "-loop" ] && [ "${args[i+1]}" = "1" ]; then
            is_loop_image=true
        fi
    done
    
    # Se for imagem com loop, procura a duração do áudio
    if [ "$is_loop_image" = true ]; then
        for ((i=0; i<${#args[@]}; i++)); do
            if [ "${args[i]}" = "-i" ] && [ $((i + 1)) -lt ${#args[@]} ]; then
                local file="${args[i+1]}"
                # Verifica se o arquivo é de áudio
                if [[ "$file" =~ \.(mp3|wav|m4a|aac|ogg|flac)$ ]]; then
                    # Usa ffprobe para obter duração do áudio
                    audio_duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
                    audio_duration=${audio_duration%.*}
                    break
                fi
            fi
        done
        
        # Se encontrou duração de áudio, usa essa duração
        if [ $audio_duration -gt 0 ]; then
            echo "$audio_duration"
            return 0
        fi
    fi
    
    # Resto do código original para concatenação e outros tipos de entrada
    if [ "$is_concat" = true ] && [ -n "$concat_file" ]; then
        while IFS= read -r line; do
            if [[ $line =~ ^file.* ]]; then
                local file_path=$(echo "$line" | sed -E "s/^file ['\"']?([^'\"']+)['\"']?$/\1/")
                echo "-i" "$file_path" >> "$temp_inputs"
            fi
        done < "$concat_file"
    else
        for ((i=0; i<${#args[@]}; i++)); do
            if [ "${args[i]}" = "-i" ] && [ $((i + 1)) -lt ${#args[@]} ]; then
                echo -i "\"${args[i+1]}\"" >> "$temp_inputs"
            fi
        done
    fi
    
    # Faz uma única chamada do ffprobe para todos os arquivos
    if [ -s "$temp_inputs" ]; then
        local durations=$(xargs -a "$temp_inputs" ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 2>/dev/null)
        while read -r dur; do
            dur=${dur%.*}
            total_duration=$((total_duration + dur))
        done <<< "$durations"
    fi
    rm -f "$temp_inputs"
    
    echo "$total_duration"
}

# Função para restaurar o cursor e limpar recursos temporários
cleanup() {
    echo  # Adiciona uma nova linha
    echo -n -e "\033[?25h" # Restaura o cursor
    rm -f "$error_log"
    exit
}

# Configurar trap para SIGINT (Ctrl+C) e SIGTERM
trap cleanup SIGINT SIGTERM

# Função para formatar tempo
format_time() {
    local seconds=$1
    printf "%02d:%02d:%02d" $((seconds/3600)) $((seconds%3600/60)) $((seconds%60))
}

# Função para criar barra de progresso
create_progress_bar() {
    # Calcular o comprimento da linha
    line_length=$(tput cols)
    # Comprimento da barra de progressão = tamanho da linha - 58 caracteres padronizados
    local percent=$1
    local width=$((line_length > 58 ? line_length - 58 : 1))
    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    
    echo -en "${BEAM}"
    for ((i=0; i<filled; i++)); do
        echo -n "${CHAR_FILLED}"
    done
    echo -en "${BEAM}"
    for ((i=0; i<empty; i++)); do
        echo -n "${CHAR_EMPTY}"
    done
    echo -en "${RESET}"
}

# Função atualizada para criar barra estática de gravação com indicador piscante
create_static_recording_bar() {
    local line_length=$(tput cols)
    local width=$((line_length > 51 ? line_length - 51 : 1))
    
    # Alterna visibilidade do indicador
    local dot_display=""
    if [ "$recording_dot_visible" = true ]; then
        dot_display="${RECORDING}${RECORDING_DOT}${RESET}"
    else
        dot_display=" "
    fi
    
    echo -en "${RECORDING}"
    for ((i=0; i<width; i++)); do
        echo -n "▓"
    done
    echo -en "${RESET} ${dot_display}"
}

format_output_file() {
    local file_path=$1
    # Obtém a extensão do arquivo
    local extensao="${file_path##*.}"
    # Obtém o basename (nome do arquivo sem o diretório e sem a extensão)
    local basename="${file_path%.*}"
    basename="${basename##*/}"  # Remove o caminho do diretório
    
    # Verifica o comprimento do nome do arquivo antes da extensão
    if [ ${#basename} -gt 15 ]; then
        # Trunca para os primeiros 15 caracteres e adiciona reticências
        echo "${basename:0:15}….$extensao"
    elif [ ${#basename} -eq 15 ]; then
        # Adiciona reticências e barra no início e a extensão
        echo "/${basename}.$extensao"
    else
        # Se for menor que 15, pega os últimos 19 caracteres do caminho completo
        local full_path=$(realpath "$file_path")
        if [ ${#full_path} -gt 19 ]; then
            # Se o caminho completo for maior que 19, pega os últimos 19 caracteres
            echo "…${full_path: -19}"
        else
            # Se for menor que 19, mostra o caminho completo com reticências no início
            echo "…${full_path}"
        fi
    fi
}

# Função atualizada para verificar se é apenas uma operação de informação
is_info_operation() {
    local has_input=false
    local has_output=false
    local input_file=""
    local is_input_next=false
    local args=("$@")
    
    for ((i=0; i<${#args[@]}; i++)); do
        if [ "$is_input_next" = true ]; then
            input_file="${args[i]}"
            is_input_next=false
            continue
        fi
        
        if [ "${args[i]}" = "-i" ]; then
            has_input=true
            is_input_next=true
            continue
        fi
        
        # Verifica se o argumento atual é uma opção de saída conhecida do ffmpeg
        if [[ "${args[i]}" =~ ^-(c|codec|f|format|map|b|q|quality|preset|crf|ab|vb|ar|ac|vf|af|s|r|aspect|vn|an|sn|y)$ ]]; then
            has_output=true
        fi
        
        # Verifica se é um arquivo de saída
        if [[ "${args[i]}" =~ \.(${supported_extensions})$ ]] && [ "${args[i]}" != "$input_file" ]; then
            has_output=true
        fi
    done
    
    # É operação de informação se tem input mas não tem output nem opções de codificação
    if [ "$has_input" = true ] && [ "$has_output" = false ]; then
        return 0
    else
        return 1
    fi
}

# Verifica argumentos
if [ $# -lt 1 ]; then
    echo "Uso: $0 [opções do ffmpeg]"
    echo "Exemplo: $0 -i input.mp4 -c copy output.mkv"
    exit 1
fi

# Encontra o arquivo de saída
supported_extensions="mp4|mkv|avi|mov|wmv|mp3|wav|m4a|m4v|webm|flv|gif|mpg|mpeg|vob|ogg|ogv|3gp|3g2|asf|rm|rmvb|flac|aac|mka|jpg|jpeg|png|tiff|bmp"
output_file=""
for arg in "$@"; do
    if [[ $arg =~ \.(${supported_extensions})$ ]]; then
        output_file="$arg"
    fi
done

# Cria um arquivo temporário para armazenar erros
error_log=$(mktemp)

# Oculta o cursor antes de iniciar o processamento
echo -n -e "\033[?25l"

# Se for operação de informação, executa ffmpeg diretamente e mostra a saída
if is_info_operation "$@"; then
    ffmpeg "$@" 2>"$error_log"
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "${ERROR}FFmpeg Configuration and File Details:${RESET}"
        echo -e "${WARNING}$(cat "$error_log")${RESET}"
    fi
    cleanup
fi

# Se não for operação de informação, verifica arquivo de saída
if [ -z "$output_file" ]; then
    echo -e "${ERROR}Arquivo de saída não encontrado!${RESET}"
    cleanup
fi

# Verifica se o arquivo já existe e pede confirmação
if [ -f "$output_file" ]; then
    echo -en "${PROMPT}O arquivo ${output_file} já existe. Deseja substituir? [s/N] ${RESET}"
    read -r response
    case "$response" in
        [sS]|[yY])
            rm -f "$output_file"
            ;;
        *)
            echo -e "${WARNING}Operação cancelada.${RESET}"
            cleanup
            ;;
    esac
fi

# Verifica se é uma gravação ao vivo
is_live_recording=false
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "-f" ]]; then
        next=$((i + 1))
        if [ $next -le $# ]; then
            # Lista de formatos de captura ao vivo
            case "${!next}" in
                alsa|pulse|avfoundation|dshow|gdigrab|decklink|x11grab|v4l2|vfwcap|lavfi|pipewire)
                    is_live_recording=true
                    break
                    ;;
            esac
        fi
    fi
done

# Tratamento de duração
if [ -z "$duration" ] || [ "$duration" -le 0 ]; then
    # Se não conseguir determinar a duração, usa a opção -shortest
    if [[ " $*" == *" -shortest"* ]]; then
        duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -i "$(echo "$@" | grep -oP '(?<=-i )[^ ]+' | grep -E '\.(mp3|wav|m4a|mp4|avi|mov)$' | head -n1)" 2>/dev/null)
        
        # Verifica se a duração é um número válido
        if [[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            duration=${duration%.*}
        else
            duration=0
        fi
    fi
fi

# Se não for gravação ao vivo, calcula a duração total
if [ "$is_live_recording" = false ]; then
    # Calcula a duração total de todos os arquivos de entrada
    duration=$(calculate_total_duration "$@")
    
    # Ajusta a duração se -t foi especificado
    for ((i=1; i<=$#; i++)); do
        if [ "${!i}" = "-t" ] && [ $((i + 1)) -le $# ]; then
            next=$((i + 1))
            t_value="${!next}"
            duration=$t_value
            break
        fi
    done
    
    if [ -z "$duration" ] || [ "$duration" -eq 0 ]; then
        echo -e "${ERROR}Não foi possível determinar a duração dos arquivos de entrada!${RESET}"
        cleanup
    fi
fi

# Variáveis para ETA e tempo de gravação
start_time=$(date +%s)
last_progress=0
progress_buffer=()

# Define a codificação do terminal para UTF-8
export LANG=en_US.UTF-8

# Formata o nome do arquivo de saída
formatted_output_file=$(format_output_file "$output_file")

# Função para calcular a média do buffer de progresso
calculate_average_progress() {
    local sum=0
    local count=${#progress_buffer[@]}
    for value in "${progress_buffer[@]}"; do
        sum=$((sum + value))
    done
    if [ $count -gt 0 ]; then
        echo $((sum / count))
    else
        echo 0
    fi
}

# Se for gravação ao vivo
if [ "$is_live_recording" = true ]; then
    echo -e "${PROMPT}Iniciando gravação ao vivo...${RESET}"
    echo -e "${PROMPT}Pressione Ctrl+C para interromper a gravação${RESET}"
    
    ffmpeg "$@" 2>"$error_log" &
    FFMPEG_PID=$!
    
    while kill -0 $FFMPEG_PID 2>/dev/null; do
        current_time=$(($(date +%s) - start_time))
        printf "\r%-${line_length}s" ""  # Limpa a linha antes de atualizar
        echo -en "\r ⭕ ${RECORDING}Recording${RESET} ${RECORDING}${formatted_output_file}${RESET} ${RECORDING}|${RESET} "
        create_static_recording_bar
        echo -en " ${RECORDING}|${RESET} ${RECORDING}$(format_time $current_time)${RESET}"
        
        # Alterna o estado do indicador
        if [ "$recording_dot_visible" = true ]; then
            recording_dot_visible=false
        else
            recording_dot_visible=true
        fi
        
        sleep 0.5  # Reduzido para 0.5 segundos para piscar mais rapidamente
    done
    
    wait $FFMPEG_PID
    exit_code=$?
else
    # Mostra barra de progresso inicial com 0%
    printf "\r%-${line_length}s" ""  # Limpa a linha antes de atualizar
    echo -en "\r 🎞  ${FILENAMELABEL}Rendering${RESET} ${FILENAME}${formatted_output_file}${RESET} | "
    create_progress_bar 0
    printf " ${PERCENTAGE}%3d%%${RESET} | ${ETALABEL}ETA${RESET} ${ETA}--:--:--${RESET}" "0"
    
    # Executa ffmpeg com todos os argumentos originais para processamento normal
    ffmpeg "$@" -progress pipe:1 2>"$error_log" | while read line; do
        key="${line%=*}"
        value="${line#*=}"
        
        case "$key" in
            "out_time")
                # Extrai segundos do formato HH:MM:SS.MS
                current_time=$(echo "$value" | awk -F: '{print ($1 * 3600) + ($2 * 60) + int($3)}')
                if [ -n "$current_time" ] && [ -n "$duration" ] && [ "$duration" -gt 0 ]; then
                    # Calcula porcentagem
                    percent=$((current_time * 100 / duration))
                    [ $percent -gt 100 ] && percent=100
                    
                    # Adiciona ao buffer e mantém apenas os últimos 3 valores
                    progress_buffer+=($percent)
                    if [ ${#progress_buffer[@]} -gt 3 ]; then
                        progress_buffer=("${progress_buffer[@]:1}")
                    fi
                    
                    # Usa a média do buffer como progresso atual
                    smoothed_percent=$(calculate_average_progress)
                    
                    # Calcula ETA
                    elapsed=$(($(date +%s) - start_time))
                    if [ $smoothed_percent -gt 0 ] && [ $elapsed -gt 0 ]; then
                        total_time=$((elapsed * 100 / smoothed_percent))
                        eta=$((total_time - elapsed))
                    else
                        eta=0
                    fi
                    
                    # Atualiza apenas se o progresso mudou significativamente
                    if [ $((smoothed_percent - last_progress)) -ge 1 ] || [ $smoothed_percent -eq 100 ]; then
                        # Limpa linha anterior
                        printf "\r%-${line_length}s" ""
                        
                        # Mostra progresso com cores exatas e percentual formatado
                        echo -en "\r 🎞  ${FILENAMELABEL}Rendering${RESET} ${FILENAME}${formatted_output_file}${RESET} | "
                        create_progress_bar $smoothed_percent
                        printf " ${PERCENTAGE}%3d%%${RESET} | ${ETALABEL}ETA${RESET} ${ETA}%s${RESET} " "$smoothed_percent" "$(format_time $eta)"
                        
                        last_progress=$smoothed_percent
                    fi
                fi
                ;;
        esac
    done
    
    # Pega o status de saída do ffmpeg
    exit_code=${PIPESTATUS[0]}
fi

if [ $exit_code -eq 0 ]; then
    if [ "$is_live_recording" = true ]; then
        current_time=$(($(date +%s) - start_time))
        echo -e "\n${PROMPT}Gravação concluída! Duração total: $(format_time $current_time)${RESET}"
    else
        # Sucesso - mostra 100%
        echo -en "\r 🎞  ${FILENAMELABEL}Rendering${RESET} ${FILENAME}${formatted_output_file}${RESET} | "
        create_progress_bar 100
        printf " ${PERCENTAGE}%3d%%${RESET} | ${ETALABEL}ETA${RESET} ${ETA}00:00:00${RESET} \n" "100"
        echo -e "${PROMPT}Processamento concluído com sucesso!${RESET}"
    fi
else
    # Erro - mostra a mensagem de erro do ffmpeg diretamente
    echo ""
    echo -e "${ERROR}FFmpeg Configuration and File Details:${RESET}"
    echo -e "${WARNING}$(cat "$error_log")${RESET}"
fi

echo -n -e "\033[?25h" # Restaura o cursor
