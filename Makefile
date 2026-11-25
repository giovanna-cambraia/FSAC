# Makefile for FSAC HAL tests

CC = gcc
CFLAGS = -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Wshadow -I../include
# Add coverage flags here
COV_FLAGS = -fprofile-arcs -ftest-coverage

# Put all generated files in this directory
BUILD_DIR = build

# Define your targets (the test executables)
TARGETS = $(BUILD_DIR)/test_secure_boot.exe \
          $(BUILD_DIR)/test_gw_1553.exe \
          $(BUILD_DIR)/test_sensor_ingest.exe

# Default target: build everything
all: $(TARGETS)

# Rule to compile secure_boot
$(BUILD_DIR)/test_secure_boot.exe: test_secure_boot.c ../src/secure_boot/fsac_secure_boot.c
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $(COV_FLAGS) -o $@ test_secure_boot.c ../src/secure_boot/fsac_secure_boot.c

# Rule to compile gw_1553 (Adjust source files as needed)
$(BUILD_DIR)/test_gw_1553.exe: test_gw_1553.c ../src/gw_1553/fsac_gw_1553.c
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $(COV_FLAGS) -o $@ test_gw_1553.c ../src/gw_1553/fsac_gw_1553.c

# Rule to compile sensor_ingest (Adjust source files as needed)
$(BUILD_DIR)/test_sensor_ingest.exe: test_sensor_ingest.c ../src/sensors/fsac_sensor_ingest.c
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $(COV_FLAGS) -o $@ test_sensor_ingest.c ../src/sensors/fsac_sensor_ingest.c

# Rule to run the tests and generate coverage data
test: all
	./$(BUILD_DIR)/test_secure_boot.exe
	./$(BUILD_DIR)/test_gw_1553.exe
	./$(BUILD_DIR)/test_sensor_ingest.exe
	gcov -o $(BUILD_DIR) *.c

# Rule to clean up all build artifacts
clean:
	rm -rf $(BUILD_DIR)
	rm -f *.gcov