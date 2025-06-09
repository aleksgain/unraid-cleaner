#!/bin/bash

# Unraid Fast Duplicate File Cleanup Script (Path-Aware)
# Only processes files that exist on the same relative path across multiple disks
# Orders of magnitude faster than the full scan approach

set -euo pipefail

# Global variables
declare -a deleted_files
DRY_RUN=false
TEST_MODE=false
MAX_FILES_PER_DISK=1000

# Check for flags
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            echo "Running in DRY RUN mode - no files will be deleted"
            ;;
        --test)
            TEST_MODE=true
            echo "Running in TEST mode - processing max $MAX_FILES_PER_DISK files per disk"
            ;;
        --help)
            echo "Usage: $0 [--dry-run] [--test] [--help]"
            echo "  --dry-run: Show what would be deleted without actually deleting"
            echo "  --test: Process only first $MAX_FILES_PER_DISK files per disk for testing"
            echo "  --help: Show this help message"
            exit 0
            ;;
    esac
done

# Function to compute smart hash based on file size
compute_smart_hash() {
    local file_path="$1"
    if [[ ! -r "$file_path" ]]; then
        echo ""
        return
    fi
    
    # Get file size
    local file_size=$(stat -c%s "$file_path" 2>/dev/null || echo "0")
    local size_mb=$((file_size / 1024 / 1024))
    
    # Strategy based on file size
    if [[ $size_mb -lt 10 ]]; then
        # Small files (<10MB): Full MD5 hash
        md5sum "$file_path" 2>/dev/null | cut -d' ' -f1
    elif [[ $size_mb -lt 100 ]]; then
        # Medium files (10-100MB): First 1MB + size
        local partial_hash=$(head -c 1048576 "$file_path" 2>/dev/null | md5sum | cut -d' ' -f1)
        echo "partial_${size_mb}MB_${partial_hash}"
    else
        # Large files (>100MB): Size + First 1MB + Last 1MB + filename
        local filename=$(basename "$file_path")
        local first_mb=$(head -c 1048576 "$file_path" 2>/dev/null | md5sum | cut -d' ' -f1)
        local last_mb=$(tail -c 1048576 "$file_path" 2>/dev/null | md5sum | cut -d' ' -f1)
        
        echo "large_${size_mb}MB_${first_mb}_${last_mb}_$(echo "$filename" | md5sum | cut -d' ' -f1)"
    fi
}

# Function to get free space in bytes
get_free_space() {
    local disk_path="$1"
    if [[ -d "$disk_path" ]]; then
        df -B1 "$disk_path" 2>/dev/null | awk 'NR==2 {print $4}'
    else
        echo "0"
    fi
}

# Auto-detect Unraid disks
echo "Auto-detecting Unraid disks..."
mapfile -t disks < <(find /mnt -maxdepth 1 -type d -name "disk[0-9]*" | sort -V)

if [[ ${#disks[@]} -eq 0 ]]; then
    echo "Error: No /mnt/disk* directories found!"
    exit 1
fi

if [[ ${#disks[@]} -lt 2 ]]; then
    echo "Error: Need at least 2 disks to find duplicates!"
    exit 1
fi

echo "Found ${#disks[@]} disks:"
printf '%s\n' "${disks[@]}"
echo

# Use first disk as reference
reference_disk="${disks[0]}"
other_disks=("${disks[@]:1}")  # All disks except the first

echo "Using $reference_disk as reference disk"
echo "Comparing against: ${other_disks[*]}"
echo

# Statistics
files_checked=0
duplicates_found=0
total_files_deleted=0

echo "Scanning for path-matched duplicates..."

# Create file list for reference disk
temp_filelist=$(mktemp)
if [[ "$TEST_MODE" == true ]]; then
    echo "Creating limited file list for testing..."
    find "$reference_disk" -type f 2>/dev/null | head -n $MAX_FILES_PER_DISK > "$temp_filelist"
else
    echo "Creating full file list from $reference_disk..."
    find "$reference_disk" -type f 2>/dev/null > "$temp_filelist"
fi

total_files=$(wc -l < "$temp_filelist")
echo "Found $total_files files in $reference_disk to check"
echo

while IFS= read -r reference_file; do
    [[ -z "$reference_file" ]] && continue
    
    # Get relative path (remove disk prefix)
    relative_path="${reference_file#$reference_disk/}"
    
    # Find matching files on other disks
    declare -a matching_files
    matching_files=("$reference_file")  # Start with reference file
    
    for other_disk in "${other_disks[@]}"; do
        candidate_file="$other_disk/$relative_path"
        
        if [[ -f "$candidate_file" ]]; then
            matching_files+=("$candidate_file")
        fi
    done
    
    # Only process if we found matches on other disks
    if [[ ${#matching_files[@]} -gt 1 ]]; then
        # Compute checksums only for matching files
        declare -A file_checksums
        declare -A file_sizes
        
        # Initialize arrays to ensure they exist
        file_checksums=()
        file_sizes=()
        
        for file in "${matching_files[@]}"; do
            checksum=$(compute_smart_hash "$file")
            if [[ -n "$checksum" ]]; then
                file_checksums["$file"]="$checksum"
                # Get file size
                file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
                file_sizes["$file"]="$file_size"
            fi
        done
        
        # Group files by checksum using temporary files to avoid space issues
        temp_checksum_dir=$(mktemp -d)
        
        for file in "${!file_checksums[@]}"; do
            checksum="${file_checksums[$file]}"
            # Create a file for each checksum and append file paths to it
            echo "$file" >> "$temp_checksum_dir/$checksum"
        done
        
        # Process each checksum file (each represents a group of files with same checksum)
        for checksum_file in "$temp_checksum_dir"/*; do
            [[ -f "$checksum_file" ]] || continue
            
            # Count lines to see if we have duplicates
            file_count=$(wc -l < "$checksum_file")
            
            if [[ $file_count -gt 1 ]]; then
                duplicates_found=$((duplicates_found + 1))
                
                # Read all files for this checksum into an array
                declare -a group_files
                while IFS= read -r file; do
                    group_files+=("$file")
                done < "$checksum_file"
                
                # Get the relative path (same for all files in group)
                first_file="${group_files[0]}"
                relative_path="${first_file#$reference_disk/}"
                
                # Get file size (same for all identical files) - with error checking
                file_size="0"
                if [[ -v "file_sizes[$first_file]" ]]; then
                    file_size="${file_sizes[$first_file]}"
                else
                    # Fallback to getting size directly if not in array
                    file_size=$(stat -c%s "$first_file" 2>/dev/null || echo "0")
                fi
                
                # Extract disk names from all files
                declare -a disk_names
                for file in "${group_files[@]}"; do
                    if [[ "$file" =~ ^/mnt/(disk[0-9]+)/ ]]; then
                        disk_names+=("${BASH_REMATCH[1]}")
                    fi
                done
                
                # Ensure we have disk names and remove duplicates
                if [[ ${#disk_names[@]} -lt 2 ]]; then
                    unset group_files
                    unset disk_names
                    continue  # Skip if we don't have at least 2 disks
                fi
                
                # Remove duplicate disk names (in case same disk appears multiple times)
                declare -A seen_disks
                declare -a unique_disk_names
                for disk in "${disk_names[@]}"; do
                    if [[ -z "${seen_disks[$disk]:-}" ]]; then
                        seen_disks["$disk"]=1
                        unique_disk_names+=("$disk")
                    fi
                done
                
                # Create disk list string
                if [[ ${#unique_disk_names[@]} -eq 2 ]]; then
                    disk_list="${unique_disk_names[0]} and ${unique_disk_names[1]}"
                elif [[ ${#unique_disk_names[@]} -gt 2 ]]; then
                    # More than 2 disks - create comma-separated list
                    disk_list=""
                    for ((i=0; i<${#unique_disk_names[@]}; i++)); do
                        if [[ $i -eq 0 ]]; then
                            disk_list="${unique_disk_names[i]}"
                        elif [[ $i -eq $((${#unique_disk_names[@]} - 1)) ]]; then
                            disk_list="$disk_list and ${unique_disk_names[i]}"
                        else
                            disk_list="$disk_list, ${unique_disk_names[i]}"
                        fi
                    done
                else
                    # Only one unique disk - shouldn't happen but handle gracefully
                    unset group_files
                    unset disk_names
                    unset seen_disks
                    unset unique_disk_names
                    continue
                fi
                
                # Output in the requested format
                echo "Duplicate found: /$relative_path (size=$file_size) exists on $disk_list"
                
                if [[ "$DRY_RUN" != true ]]; then
                    # Create temporary file to store disk info for deletion logic
                    temp_diskinfo=$(mktemp)
                    
                    for file in "${group_files[@]}"; do
                        # Extract disk from file path
                        if [[ "$file" =~ ^(/mnt/disk[0-9]+)/ ]]; then
                            disk_path="${BASH_REMATCH[1]}"
                        else
                            continue
                        fi
                        
                        free_space=$(get_free_space "$disk_path")
                        printf "%s\t%s\n" "$free_space" "$file" >> "$temp_diskinfo"
                    done
                    
                    # Sort by free space (descending) using temp file
                    sort -rn -t$'\t' -k1 "$temp_diskinfo" > "${temp_diskinfo}.sorted"
                    
                    # Read the first line to get the file to keep
                    IFS=$'\t' read -r kept_space kept_file < "${temp_diskinfo}.sorted"
                    
                    # Process remaining lines for deletion
                    line_num=0
                    while IFS=$'\t' read -r file_space file_path; do
                        line_num=$((line_num + 1))
                        if [[ $line_num -eq 1 ]]; then
                            continue  # Skip first line (already processed as kept file)
                        fi
                        
                        if [[ -f "$file_path" ]]; then
                            if rm "$file_path" 2>/dev/null; then
                                deleted_files+=("$file_path")
                                total_files_deleted=$((total_files_deleted + 1))
                            fi
                        fi
                    done < "${temp_diskinfo}.sorted"
                    
                    # Cleanup temp files
                    rm -f "$temp_diskinfo" "${temp_diskinfo}.sorted"
                fi
                
                # Clear arrays for next iteration
                unset group_files
                unset disk_names
                unset seen_disks
                unset unique_disk_names
            fi
        done
        
        # Cleanup temporary directory
        rm -rf "$temp_checksum_dir"
        
        # Cleanup for this iteration
        unset file_checksums
        unset file_sizes
    fi
    
    files_checked=$((files_checked + 1))
    
    # Progress indicator - less frequent to avoid cluttering output with duplicates
    if (( files_checked % 500 == 0 )); then
        echo "Progress: $files_checked/$total_files files checked, $duplicates_found duplicate groups found"
    fi
    
done < "$temp_filelist"

# Cleanup
rm -f "$temp_filelist"

# Final summary
echo
echo "=== SUMMARY ==="
echo "Files checked: $files_checked"
echo "Duplicate groups found: $duplicates_found"

if [[ "$DRY_RUN" == true ]]; then
    echo "Mode: DRY RUN (no files were deleted)"
else
    echo "Files deleted: $total_files_deleted"
    echo "Mode: DELETION (duplicates were removed, keeping files on disks with most free space)"
fi

echo "Fast path-aware scan completed!" 