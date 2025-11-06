#!/bin/bash
#
# sys_monitor.sh
# Linux System Monitoring & Maintenance Automation Tool
# Features:
#  - System Health Report
#  - User Management (list, add, remove)
#  - Process Monitoring (top processes, kill by PID)
#  - Backup Important Files (timestamped tar.gz)
#  - Log File Report (scan /var/log for errors/warnings)
#  - Simple threshold alerts (print warnings when high usage)
#
# Usage:
#   chmod +x sys_monitor.sh
#   ./sys_monitor.sh
#
# Tested on bash (typical Linux distros). Use sudo for full features.
#

### ---------- Configuration ----------
BACKUP_DIR="/var/backups/sys_monitor"
ALERT_CPU=80        # percent
ALERT_MEM=80        # percent
ALERT_DISK=80       # percent (per filesystem)
LOG_SCAN_KEYWORDS=("error" "fail" "failed" "exception" "panic" "segfault" "warn")

### ---------- Colors ----------
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
BOLD="\e[1m"
RESET="\e[0m"

### ---------- Helpers ----------
timestamp() { date +"%Y-%m-%d_%H-%M-%S"; }

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}Warning:${RESET} Some operations require root privileges (run with sudo)."
    fi
}

pause() {
    echo
    read -p "Press Enter to continue..." _dummy
}

clear_screen() {
    printf "\033c"
}

print_header() {
    clear_screen
    echo -e "${BOLD}${BLUE}-----------------------------------------------${RESET}"
    echo -e "${BOLD}${BLUE}   LINUX SYSTEM MONITORING & MAINTENANCE TOOL  ${RESET}"
    echo -e "${BOLD}${BLUE}-----------------------------------------------${RESET}"
    echo
}

### ---------- Feature 1: System Health ----------
system_health_report() {
    print_header
    echo -e "${BOLD}System Health Report (${timestamp()}):${RESET}"
    echo

    # Uptime & load
    echo -e "${BOLD}Uptime & Load:${RESET}"
    uptime
    echo

    # CPU usage (using top summary)
    echo -e "${BOLD}CPU Usage:${RESET}"
    # try mpstat if available for per-cpu, else use top -bn1
    if command -v mpstat >/dev/null 2>&1; then
        mpstat 1 1
    else
        top -bn1 | grep "Cpu(s)" || top -bn1 | head -n 5
    fi
    echo

    # Memory
    echo -e "${BOLD}Memory Usage:${RESET}"
    free -h
    echo

    # Disk usage
    echo -e "${BOLD}Disk Usage (by filesystem):${RESET}"
    df -hT | awk 'NR==1 || /^\\/dev\\// {print}'
    echo

    # Top CPU consumers
    echo -e "${BOLD}Top Processes by CPU:${RESET}"
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 11
    echo

    # Top memory consumers
    echo -e "${BOLD}Top Processes by Memory:${RESET}"
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -n 11
    echo

    # Alert checks
    echo -e "${BOLD}Alerts:${RESET}"
    # CPU: compute avg usage (100 - idle)
    CPU_IDLE_LINE=$(top -bn1 | grep "Cpu(s)" | head -n1)
    if [ -n "$CPU_IDLE_LINE" ]; then
        # Attempt to extract idle percentage
        IDLE=$(echo "$CPU_IDLE_LINE" | awk -F',' '{ for(i=1;i<=NF;i++){ if($i ~ /id/) print $i } }' | tail -n1 | awk '{print $1}' | sed 's/%//g')
        if [[ $IDLE =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            CPU_USAGE=$(awk "BEGIN {print 100 - $IDLE}")
            CPU_USAGE_INT=${CPU_USAGE%.*}
            if [ "$CPU_USAGE_INT" -ge "$ALERT_CPU" ]; then
                echo -e "${RED}High CPU usage detected: ${CPU_USAGE}%${RESET}"
            else
                echo -e "${GREEN}CPU usage: ${CPU_USAGE}%${RESET}"
            fi
        fi
    fi

    # Memory percent used
    MEM_PERCENT=$(free | awk '/Mem:/ {printf("%.0f", $3/$2 * 100)}')
    if [ -n "$MEM_PERCENT" ]; then
        if [ "$MEM_PERCENT" -ge "$ALERT_MEM" ]; then
            echo -e "${RED}High Memory usage: ${MEM_PERCENT}%${RESET}"
        else
            echo -e "${GREEN}Memory usage: ${MEM_PERCENT}%${RESET}"
        fi
    fi

    # Disk per-filesystem
    while read -r usep fs; do
        usep_n=${usep%\%}
        if [ "$usep_n" -ge "$ALERT_DISK" ]; then
            echo -e "${RED}High disk usage on ${fs}: ${usep}${RESET}"
        fi
    done < <(df -h --output=pcent,target | tail -n +2 | awk '{print $1" "$2}')

    pause
}

### ---------- Feature 2: User Management ----------
manage_users() {
    while true; do
        print_header
        echo -e "${BOLD}User Management:${RESET}"
        echo "1) List users (system & normal)"
        echo "2) Add user"
        echo "3) Remove user"
        echo "4) Change user password"
        echo "5) Back to main menu"
        echo
        read -p "Enter choice [1-5]: " ch
        case "$ch" in
            1)
                echo -e "${BOLD}All users (from /etc/passwd):${RESET}"
                awk -F: '{ printf("%-20s UID:%-6s Home:%-30s Shell:%s\n",$1,$3,$6,$7) }' /etc/passwd
                pause
                ;;
            2)
                read -p "Enter new username: " uname
                if id "$uname" >/dev/null 2>&1; then
                    echo -e "${YELLOW}User already exists.${RESET}"
                else
                    if [ "$EUID" -ne 0 ]; then
                        echo -e "${RED}You need root privileges to add a user. Use sudo.${RESET}"
                    else
                        read -p "Create home directory? (y/n) [y]: " yn
                        yn=${yn:-y}
                        if [ "$yn" = "y" ]; then
                            useradd -m "$uname"
                        else
                            useradd "$uname"
                        fi
                        passwd "$uname"
                        echo -e "${GREEN}User $uname created.${RESET}"
                    fi
                fi
                pause
                ;;
            3)
                read -p "Enter username to remove: " rname
                if ! id "$rname" >/dev/null 2>&1; then
                    echo -e "${YELLOW}User not found.${RESET}"
                else
                    if [ "$EUID" -ne 0 ]; then
                        echo -e "${RED}You need root privileges to remove a user. Use sudo.${RESET}"
                    else
                        read -p "Remove home directory as well? (y/n) [n]: " yn
                        yn=${yn:-n}
                        if [ "$yn" = "y" ]; then
                            userdel -r "$rname"
                        else
                            userdel "$rname"
                        fi
                        echo -e "${GREEN}User $rname removed.${RESET}"
                    fi
                fi
                pause
                ;;
            4)
                read -p "Enter username to update password: " pname
                if ! id "$pname" >/dev/null 2>&1; then
                    echo -e "${YELLOW}User not found.${RESET}"
                else
                    if [ "$EUID" -ne 0 ]; then
                        echo -e "${RED}You need root privileges to change password. Use sudo.${RESET}"
                    else
                        passwd "$pname"
                        echo -e "${GREEN}Password updated for $pname.${RESET}"
                    fi
                fi
                pause
                ;;
            5) break ;;
            *) echo "Invalid choice." ; pause ;;
        esac
    done
}

### ---------- Feature 3: Process Monitoring ----------
process_monitoring() {
    while true; do
        print_header
        echo -e "${BOLD}Process Monitoring:${RESET}"
        echo "1) Show top 10 processes by CPU"
        echo "2) Show top 10 processes by RAM"
        echo "3) Kill a process by PID"
        echo "4) Back to main menu"
        echo
        read -p "Enter choice [1-4]: " ch
        case "$ch" in
            1)
                echo -e "${BOLD}Top processes by CPU:${RESET}"
                ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 11
                pause
                ;;
            2)
                echo -e "${BOLD}Top processes by Memory:${RESET}"
                ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -n 11
                pause
                ;;
            3)
                read -p "Enter PID to kill: " pid
                if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
                    echo -e "${YELLOW}PID must be numeric.${RESET}"
                else
                    if kill -9 "$pid" >/dev/null 2>&1; then
                        echo -e "${GREEN}Process $pid killed.${RESET}"
                    else
                        echo -e "${RED}Failed to kill $pid. Check permissions or PID existence.${RESET}"
                    fi
                fi
                pause
                ;;
            4) break ;;
            *) echo "Invalid choice." ; pause ;;
        esac
    done
}

### ---------- Feature 4: Backup ----------
perform_backup() {
    print_header
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}Warning:${RESET} backup to ${BACKUP_DIR} may need root privileges to access some files."
    fi
    echo -e "${BOLD}Backup Important Files:${RESET}"
    echo "1) Backup /etc"
    echo "2) Backup /home"
    echo "3) Backup custom path"
    echo "4) Back to main menu"
    read -p "Choose option [1-4]: " ch
    case "$ch" in
        1) SRC="/etc" ;;
        2) SRC="/home" ;;
        3) read -p "Enter absolute path to backup: " SRC ;;
        4) return ;;
        *) echo "Invalid choice." ; pause ; return ;;
    esac

    if [ ! -d "$SRC" ]; then
        echo -e "${RED}Source path not found: $SRC${RESET}"
        pause
        return
    fi

    mkdir -p "$BACKUP_DIR" 2>/dev/null
    outfile="${BACKUP_DIR}/backup_$(basename ${SRC})_$(timestamp).tar.gz"
    echo -e "${BOLD}Creating backup of ${SRC} → ${outfile}${RESET}"
    tar -czf "$outfile" -C / "$(echo "$SRC" | sed 's|^/||')" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Backup created at: ${outfile}${RESET}"
    else
        echo -e "${RED}Backup failed. Check permissions and available disk space.${RESET}"
    fi
    pause
}

### ---------- Feature 5: Log File Report ----------
log_file_report() {
    print_header
    echo -e "${BOLD}Log File Scanner:${RESET}"
    echo "This will search common logs in /var/log for keywords: ${LOG_SCAN_KEYWORDS[*]}"
    echo
    # common log files
    LOGS=(/var/log/messages /var/log/syslog /var/log/auth.log /var/log/secure /var/log/kern.log /var/log/dmesg)
    found_any=false
    for logfile in "${LOGS[@]}"; do
        if [ -f "$logfile" ]; then
            echo -e "${BLUE}Scanning $logfile...${RESET}"
            # use case-insensitive search
            GREP_PATTERN=$(printf "%s\\|" "${LOG_SCAN_KEYWORDS[@]}")
            GREP_PATTERN=${GREP_PATTERN%\\|}
            matches=$(grep -iE "$GREP_PATTERN" "$logfile" | tail -n 20)
            if [ -n "$matches" ]; then
                echo -e "${YELLOW}Recent matches in $logfile:${RESET}"
                echo "$matches"
                found_any=true
            fi
            echo
        fi
    done

    if [ "$found_any" = false ]; then
        echo -e "${GREEN}No recent error/warning keywords found in checked logs (or logs absent).${RESET}"
    fi
    pause
}

### ---------- Menu & Main Loop ----------
main_menu() {
    require_root
    while true; do
        print_header
        echo "1) View System Health Report"
        echo "2) Manage Users (add/remove/list)"
        echo "3) Monitor Running Processes"
        echo "4) Backup Important Files"
        echo "5) Scan Log Files (errors/warnings)"
        echo "6) Configure Alert Thresholds (CPU/MEM/DISK)"
        echo "7) Exit"
        echo
        read -p "Enter your choice [1-7]: " choice
        case "$choice" in
            1) system_health_report ;;
            2) manage_users ;;
            3) process_monitoring ;;
            4) perform_backup ;;
            5) log_file_report ;;
            6)
                read -p "Set CPU alert threshold (%) [${ALERT_CPU}]: " tmp
                if [[ "$tmp" =~ ^[0-9]+$ ]]; then ALERT_CPU=$tmp; fi
                read -p "Set MEM alert threshold (%) [${ALERT_MEM}]: " tmp
                if [[ "$tmp" =~ ^[0-9]+$ ]]; then ALERT_MEM=$tmp; fi
                read -p "Set DISK alert threshold (%) [${ALERT_DISK}]: " tmp
                if [[ "$tmp" =~ ^[0-9]+$ ]]; then ALERT_DISK=$tmp; fi
                echo -e "${GREEN}Thresholds updated: CPU=${ALERT_CPU}% MEM=${ALERT_MEM}% DISK=${ALERT_DISK}%${RESET}"
                pause
                ;;
            7) echo "Goodbye." ; exit 0 ;;
            *) echo "Invalid option." ; pause ;;
        esac
    done
}

### ---------- Entry point ----------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Run interactive menu
    main_menu
fi
