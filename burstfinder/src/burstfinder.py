# Burstfinder takes a sequence of pulses and uses the Lotek codeset to identify each burst of pulses that matches a known code.
import os, sys, time, gzip, struct, threading, queue, argparse, yaml, logging, traceback
import numpy as np

logging.basicConfig(level=logging.INFO, handlers=[])

# High confidence criteria for matching bursts to codes
BURST_CRITERIA_HI = dict(
	WARNING = 0, # 0 = High quality
	MAX_PULSE_SLOP = 0.0004, # [s] Max variation in pulse intervals for matching a burst to a code
	MAX_FREQ_RANGE = 0.05, # [kHz] Max difference between max and min frequency of pulses within a burst
	MAX_FREQ_OUTLIERS = 0, # [] Max number of pulses that are allowed to be outside of the max frequency range (required to detect bursts where a pulse is being maksed by a pulse from another burst).
	MAX_USED_PULSES = 0, # [] Max number of pulses that can be used in more than one burst
	MAX_SIG_RANGE = 10, # [dB] Max difference between max and min signal strength of pulses within a burst
)

# Low confidence criteria for matching bursts to codes
BURST_CRITERIA_LO = dict(
	WARNING = 1, # 1 = Low quality
	MAX_PULSE_SLOP = 0.0015, # [s] Max variation in pulse intervals for matching a burst to a code
	MAX_FREQ_RANGE = 0.1, # [kHz] Max difference between max and min frequency of pulses within a burst
	MAX_FREQ_OUTLIERS = 1, # [] Max number of pulses that are allowed to be outside of the max frequency range (required to detect bursts where a pulse is being maksed by a pulse from another burst).
	MAX_USED_PULSES = 1, # [] Max number of pulses that can be used in more than one burst
	MAX_SIG_RANGE = 20, # [dB] Max difference between max and min signal strength of pulses within a burst
)

# File name suffixes for the pulse, burst, and burstpulse files
SUFFIX_PULSES = '-all.txt'

# Abort pulse file processing after this number of consecutively unreadable lines
MAX_PULSE_FILE_WARNINGS = 10

# Pulses less than 1.5 ms apart are usually an artifact of the receiver hardware/software and not two real, separate pulses
# Burstfinder will treat such pairs of pulses as a single pulse by taking the one with the strong signal
MIN_PULSE_SEPARATION = 0.0015 # [s]

# Only look for "low quality" bursts if there are fewer than this number of pulses in the pulse buffer
# Otherwise combinatorial possibilities begin to grow rapidly and and performance (speed and accuracy) suffers
MAX_PULSES_IN_WINDOW_FOR_LOW_QUALITY_BURSTS = 12

# These functions are use to validate that the timestamps in the pulse files fall within a reasonable range
def get_earliest_timestamp():
	return 1262304000  # 2010-01-01 00:00:00 UTC
def get_latest_timestamp():
	return time.time() + 86400*30 # 1 month from runtime

# START and DURATION parameters can be used to process only some subset of the pulse files (for debugging)
START = 0 # [s]
DURATION = np.inf # [s]

# Enum for pulse file columns
class PULSE_COLS:
	ANT = 0; TS = 1; FREQ = 2; SIG = 3; NOISE = 4; USED = 5
	HEADER = 'Antenna ID,Unix timestamp (s),Frequency offset (kHz),Signal strength (dB),Noise (dB),Bursts using this pulse'
	SHORT_HEADER = 'ant,ts,freq,sig,noise,used'

# Enum for burst file columns
class BURST_COLS:
	ANT = 0; TS = 1; ID = 2; FREQ_MEAN = 3; FREQ_SD = 4; FREQ_RANGE = 5; SIG_MEAN = 6; SIG_SD= 7; SIG_RANGE = 8; NOISE_MEAN = 9; SLOP = 10;
	SNR_MIN = 11; USED_PULSES = 12; NUM_PULSES = 13; WARNING = 14; PULSES = 15
	HEADER = 'Antenna ID,Unix timestamp (s),Lotek code ID,Frequency offset mean (kHz),Frequency offset range (kHz),Signal strength mean (dB),' \
						'Signal strength range (dB),Noise mean (dB),Max pulse slop (s),Minimum signal to noise (dB),Other bursts using this pulse,' \
						'Other pulses in the window,Warning flag'
	SHORT_HEADER = 'ant,ts,mfgID,freq,freqSD,freqRange,sig,sigSD,sigRange,noise,slop,sig2noise,sharedPulses,pulseCount,flag'

# Class to calculate and provide some code data
class Codes:
	def __init__(self, code_intervals):
		ids = np.array(list(code_intervals.keys()))
		intervals = np.array(list(code_intervals.values()))/1000 # Get all intervals in seconds
		intervals_min = intervals.min(axis=0) # Shortest code
		intervals_max = intervals.max(axis=0) # Longest code
		# Determine the pulse window, the maximum time separation between the first and last pulse in a burst
		pulse_window = np.sum(intervals_max) + BURST_CRITERIA_LO['MAX_PULSE_SLOP']*2 # [s]
		# Determine the number of unique pulse intervals for each of the 3 intervals in a code
		interval_num = np.array([len(np.unique(intervals)) for intervals in intervals.T])
		# Determine the pulse interval step size (knowing that Lotek codes use a fixed step size between intervals)
		interval_step = np.mean((intervals_max - intervals_min)/(interval_num-1))
		code_lookup = dict()
		for id in code_intervals:
			intervals = np.array(code_intervals[id])/1000
			# Interpret each iterval as an integer code symbol
			symbols = np.round((intervals - intervals_min)/interval_step).astype(int)
			if symbols[2] not in code_lookup:
				code_lookup[symbols[2]] = dict()
			if symbols[1] not in code_lookup[symbols[2]]:
				code_lookup[symbols[2]][symbols[1]] = dict()
			code_lookup[symbols[2]][symbols[1]][symbols[0]] = id

		self.code_intervals = code_intervals
		self.ids = ids
		self.intervals_min = intervals_min
		self.intervals_max = intervals_max
		self.interval_step = interval_step
		self.pulse_window = pulse_window
		self.code_lookup = code_lookup

# Does some input/output handling then processes each pulse file
def main(input_path, output_path, codes_path, settings_path, output_bursts, output_pulses, include_header, output_text):
	if codes_path:
		# Load codeset from specified file
		with open(codes_path, 'r') as file:
			code_intervals = yaml.safe_load(file)
	else:
		# Otherwise load the built-in codeset
		from lotek6m_codes import code_intervals
	codes = Codes(code_intervals)

	if settings_path:
		# Load settings from specified file
		with open(settings_path, 'r') as file:
			settings = yaml.safe_load(file)
		BURST_CRITERIA_HI.update(settings['BURST_CRITERIA_HI'])
		BURST_CRITERIA_LO.update(settings['BURST_CRITERIA_LO'])

	pulse_paths = []
	# If input argument is a file, add it to the list of input files
	if input_path == 'stdin':
		logging.info('Reading pulses from stdin')
		pulse_paths.append(input_path)
	elif os.path.isfile(input_path):
		pulse_paths.append(input_path)
	# If input argument is a directory, add all pulse files in the directory (and subdirectories) to the list of input files
	elif os.path.isdir(input_path):
		for path in os.listdir(input_path):
			# If this is a subdirectory
			if os.path.isdir(os.path.join(input_path, path)):
				 # Make a parallel directory for output
				os.makedirs(os.path.join(output_path, path), exist_ok=True)
				# Call Burstfinder recursively on this directory
				main(os.path.join(input_path, path), os.path.join(output_path, path), codes_path, settings_path, output_bursts, output_pulses, include_header, output_text)
			else:
				# Add the pulse file to the list for processing
				pulse_paths.append(os.path.join(input_path, path))

	# Group pulse files by receiver
	pulse_paths_by_receiver = dict()
	for pulse_path in pulse_paths:
		receiver = '-'.join(os.path.basename(pulse_path).split('-')[:2])
		if receiver not in pulse_paths_by_receiver:
			pulse_paths_by_receiver[receiver] = [pulse_path]
		else:
			pulse_paths_by_receiver[receiver].append(pulse_path)

	# For each input pulse file, find and output bursts and/or filtered pulses
	for receiver in pulse_paths_by_receiver:
		pulse_buffers = None # Initialize with empty pulse buffers for a new receiver, otherwise remaining pulses are carried over from the previous file
		for pulse_path in sorted(pulse_paths_by_receiver[receiver]):
			if output_path == 'stdout':
				logging.info('Writing bursts to stdout')
				burst_path = None if not output_bursts else 'stdout'
				burstpulse_path = None if not output_pulses else 'stdout'
				other_path = None
			else:
				pulse_name = os.path.basename(pulse_path).replace('.txt','')
				burst_path = None if not output_bursts else f'{output_path}/{pulse_name}-bf-bursts.txt'
				burstpulse_path = None if not output_pulses else f'{output_path}/{pulse_name}-bf-burstpulses.txt'
				other_path = f'{output_path}/{pulse_name}-bf-other.txt'

			# Find the bursts in this file (or pipe).
			# If it is a file, then the burst in the buffer at the end of the file will be carried over to the next file,
			# to avoid missing any bursts that span files (if it is from the same receiver)
			try:
				pulse_buffers = find_bursts(pulse_path, burst_path, burstpulse_path, other_path, codes, include_header, output_text, pulse_buffers)
			except Exception as e:
				logging.error(f'  Error processing file {pulse_path}\n{traceback.format_exc()}')

def open_input_handle(path):
	if path == 'stdin':
		return sys.stdin
	elif path.endswith(SUFFIX_PULSES + '.gz'):
		return gzip.open(path, 'rt')
	else:
		return open(path, "r")

def open_output_handle(path, output_text):
	if path == 'stdout':
		return sys.stdout
	elif output_text:
		return open(path, "w")
	else:
		return gzip.open(path+'.gz', 'wt')

def pop_from_pulse_prebuffer(pulse_prebuffer):
	if len(pulse_prebuffer) < 2:
		return None, pulse_prebuffer

	pulse_1 = pulse_prebuffer[0]
	pulse_2 = pulse_prebuffer[1]

	# If the pulses are too close together
	if np.abs(pulse_2[PULSE_COLS.TS] - pulse_1[PULSE_COLS.TS]) < MIN_PULSE_SEPARATION:
		# Take the stronger of the two pulses
		if pulse_1[PULSE_COLS.SIG] > pulse_2[PULSE_COLS.SIG]:
			pulse = pulse_1
		else:
			pulse = pulse_2
		pulse_prebuffer.pop(0)
		pulse_prebuffer.pop(0)
	else:
		# Otherwise just provide the next pulse
		pulse = pulse_1
		pulse_prebuffer.pop(0)

	return pulse, pulse_prebuffer

def find_bursts_in_pulse_window(pulse_buffer, burst_buffer, burst_count, unique_codes, codes):
	# Remove old pulses (outside the window) from the buffer
	buffer_dt = get_buffer_dt(pulse_buffer)
	while buffer_dt > codes.pulse_window:
		pulse_buffer.pop(0)
		buffer_dt = get_buffer_dt(pulse_buffer)

	# Find some high quality bursts in the window and add them to burst buffer
	for _ in range(10):
		burst = find_burst(pulse_buffer, BURST_CRITERIA_HI, codes)
		if burst is None:
			break
		else:
			burst_count += 1
			unique_codes.add(burst[BURST_COLS.ID])
			pulse_buffer = update_used_pulses(pulse_buffer, burst)
			burst_buffer.append(burst)
			continue

	# Find some low quality bursts in the window and add them to burst buffer
	# Do this only if there are not too many pulses in the buffer, to prevent false positives and excessive processing time from noisy environments
	if len(pulse_buffer) < MAX_PULSES_IN_WINDOW_FOR_LOW_QUALITY_BURSTS:
		for _ in range(10):
			burst = find_burst(pulse_buffer, BURST_CRITERIA_LO, codes)
			if burst is None:
				break
			else:
				burst_count += 1
				unique_codes.add(burst[BURST_COLS.ID])
				pulse_buffer = update_used_pulses(pulse_buffer, burst)
				burst_buffer.append(burst)
				continue
	
	return pulse_buffer, burst_buffer, burst_count, unique_codes

def get_txt_file_size(file_path):
	return os.path.getsize(file_path)

def get_gz_file_size_uncompressed(gz_file_path):
	with open(gz_file_path, 'rb') as f:
		f.seek(-4, 2)  # Move to the last 4 bytes of the file
		uncompressed_size = struct.unpack('I', f.read(4))[0]
	return uncompressed_size

# Process a single burst file, generating 
def find_bursts(pulse_path, burst_path, burstpulse_path, other_path, codes, include_header, output_text, pulse_buffers=None):
	# Initialize start time and counters
	t = 0
	t_start = 0
	pulse_count = 0; burst_count = 0 # Initialize pulse and burst counters
	pulse_file_warnings = 0
	unique_codes = set() # Keep track of all unique codes detected
	# Initialize pulse buffers
	pulse = None
	pulse_prebuffers = dict()
	if not pulse_buffers: pulse_buffers = dict() # Initialize pulse buffers if not provided from a previous run
	burst_buffers = dict()
	# Open files
	logging.info(f'Input: {pulse_path}')
	# If this file is a .txt file
	if pulse_path.endswith(SUFFIX_PULSES):
		# Skip processing this file if there is a gz version of it AND the gz version's file size is larger
		pulse_path_gz = pulse_path + '.gz'
		if os.path.exists(pulse_path_gz) and get_gz_file_size_uncompressed(pulse_path_gz) > get_txt_file_size(pulse_path):
			logging.info(f'  Skipping this file because a larger gzipped version is available')
			return
	# If it is a .gz file
	elif pulse_path.endswith(SUFFIX_PULSES + '.gz'):
		# Skip processing this file if there is a txt version of it AND the txt version's file size is larger
		pulse_path_txt = pulse_path[:-3]
		if os.path.exists(pulse_path_txt) and get_gz_file_size_uncompressed(pulse_path) <= get_txt_file_size(pulse_path_txt):
			logging.info(f'  Skipping this file because an identical or larger uncompressed version is available')
			return
	elif pulse_path != 'stdin':
		logging.warning(f'  Invalid input file type: {pulse_path} - filename must end with "-all.txt" or "-all.txt.gz"')
		return

	f_pulse = open_input_handle(pulse_path)
	if not f_pulse:
		return
	f_burst = open_output_handle(burst_path, output_text) if burst_path else None
	if f_burst and include_header:
		f_burst.write(BURST_COLS.SHORT_HEADER+'\n')
	f_burstpulse = open_output_handle(burstpulse_path, output_text) if burstpulse_path else None
	if f_burstpulse and include_header:
		f_burstpulse.write(PULSE_COLS.SHORT_HEADER+'\n')
	f_other = open_output_handle(other_path, output_text) if other_path else None

	# Function to read all lines from a stream, to be called in a thread
	def read_lines():
		for line in f_pulse: 
			if line.startswith(('\0', 'exit')):
				Q.put('\0') # Stop reading from stdin
				break
			else:
				Q.put(line)
		Q.put('\0') # Stop reading from file

	# Create a queue for passing lines between threads
	Q = queue.Queue()
	# Create a thread for reading lines from the stream and writing them to the queue
	T = threading.Thread(target=read_lines, daemon=True)
	T.start() 

	# Iterate through the incoming pulses until end of file or timeout
	while True:
		# Abort if too many invalid lines are encountered
		if pulse_file_warnings > MAX_PULSE_FILE_WARNINGS:
			logging.warning(f'  More than {MAX_PULSE_FILE_WARNINGS} consecutive unreadable lines in pulse file - processing aborted')
			break

		# Retrieve a line from the queue, with a timeout (to support real-time processing)
		try:
			pulse_txt = Q.get(timeout=codes.pulse_window)
		except queue.Empty:
			pulse_txt = None

		# If the read operation times out or EOF is received, then process any remaining pulses in the buffer
		if pulse_txt is None or pulse_txt == '\0':
			for ant in pulse_prebuffers:
				# Initiailize any buffers that don't exist, just in case
				if ant not in pulse_buffers:
					pulse_buffers[ant] = list()
				if ant not in burst_buffers:
					burst_buffers[ant] = list()
				# Transfer all pulses from prebuffers to buffers
				while len(pulse_prebuffers[ant]) > 0:
					pulse = pulse_prebuffers[ant].pop(0)
					pulse_buffers[ant].append(pulse)
				# Detect any additional bursts using these pulses
				pulse_buffers[ant], burst_buffers[ant], burst_count, unique_codes = find_bursts_in_pulse_window(pulse_buffers[ant], burst_buffers[ant], burst_count, unique_codes, codes)
				# Write all bursts
				burst_buffers[ant] = write_bursts(burst_buffers[ant], np.inf, f_burst, f_burstpulse)
			if pulse_txt == '\0': 
				break # Stop if end of file or stream is indicated
			elif pulse_txt == None:
				continue # Continue waiting if stdin has timed out

		# Get new pulse
		pulse = parse_pulse_txt(pulse_txt)
		if pulse == 'invalid':
			pulse_file_warnings += 1
			continue
		elif pulse == 'other':
			# Not pulse data, write to "other file" (if available) and proceed to next pulse
			if f_other:
				f_other.write(pulse_txt)
			continue 

		ant = pulse[PULSE_COLS.ANT]

		t = pulse[PULSE_COLS.TS]
		if t_start == 0: t_start = t
		# Check if timestamp is in the allowed subset (fore debugging)
		if t - t_start < START:	continue
		if t - t_start > START + DURATION: break
		# Check that timestamp falls within valid range
		if t < get_earliest_timestamp() or t > get_latest_timestamp():
			logging.warning(f'  Invalid pulse timestamp {t}')
			pulse_file_warnings += 1
			continue

		# Create prebuffer if it doesn't exist
		if ant not in pulse_prebuffers:
			pulse_prebuffers[ant] = list()

		# Check if pulse time has decreased
		if len(pulse_prebuffers[ant]) > 0 and t < pulse_prebuffers[ant][-1][PULSE_COLS.TS]:
			logging.warning(f'Pulse timestamp decreased at {t}')
			pulse_file_warnings += 1
			# Time has decreased for this antenna so something is wrong - clear buffers and attempt to continue
			pulse_prebuffers[ant] = list()
			pulse_buffers[ant] = list()

		# Looks like a valid pulse - increment pulse counter and reset warning count
		pulse_count += 1
		pulse_file_warnings = 0 # Reset consecutive warning count for each valid pulse

		# First add pulses to a prebuffer, so we can examine them and handle cases where a single real pulse has been recorded as two adjacent pulses in the pulse data
		pulse_prebuffers[ant].append(pulse)
	
		pulse, pulse_prebuffers[ant] = pop_from_pulse_prebuffer(pulse_prebuffers[ant])
		if pulse is None:
			continue
		if ant not in pulse_buffers:
			pulse_buffers[ant] = list()
		pulse_buffers[ant].append(pulse)

		# Write any previously detected bursts to file, if they are now outside of the pulse window
		if ant not in burst_buffers:
			burst_buffers[ant] = list()
		pulse_window_start = t - codes.pulse_window
		burst_buffers[ant] = write_bursts(burst_buffers[ant], pulse_window_start, f_burst, f_burstpulse)

		# Find bursts in the pulse window
		pulse_buffers[ant], burst_buffers[ant], burst_count, unique_codes = find_bursts_in_pulse_window(pulse_buffers[ant], burst_buffers[ant], burst_count, unique_codes, codes)

	T.join() # Terminate reading thread

	if pulse_count > 0:
		pulses_per_burst = pulse_count/burst_count if burst_count > 0 else 0
		duration = max(1, t - t_start) # Avoid case where duration = 0
		logging.info(f'  Duration: {(duration)/60:6.1f} min | '+
				f'Pulse count: {pulse_count:7.0f} | Pulses per sec: {pulse_count/(duration):6.1f} | '+
				f'Burst count: {burst_count:7.0f} | Bursts per min: {burst_count/(duration)*60:6.1f} | '+
				f'Pulses per burst: {pulses_per_burst:6.1f} | Tag count: {len(unique_codes)}')
	else:
		logging.info(f'  No valid pulses')

	return pulse_buffers

def write_bursts(burst_buffer, pulse_window_start, f_burst, f_burstpulse):
	bursts_to_write = []
	bursts_to_keep = []
	for burst in burst_buffer:
		if burst[BURST_COLS.TS] < pulse_window_start:
			bursts_to_write.append(burst)
		else:
			bursts_to_keep.append(burst)
	bursts_to_write_agg = aggregate_bursts(bursts_to_write)
	if len(bursts_to_write_agg) > 0:
		f_burst.write(format_bursts(bursts_to_write_agg)) if f_burst else None
		f_burstpulse.write(format_burstpulses(bursts_to_write_agg)) if f_burstpulse else None
	return bursts_to_keep

def find_pulses(pulse_buffer, burst_pulses, code_lookup, burst_criteria, codes):
	interval_i = 3 - len(burst_pulses)
	pulse_next = burst_pulses[0]
	pulse_mask = pulse_buffer[:,PULSE_COLS.TS] < pulse_next[PULSE_COLS.TS]
	if burst_criteria['MAX_FREQ_OUTLIERS'] == 0:
		pulse_mask &= np.abs(pulse_buffer[:,PULSE_COLS.FREQ] - pulse_next[PULSE_COLS.FREQ]) <= burst_criteria['MAX_FREQ_RANGE']
	# For each pulse in the buffer (in reverse order), consider whether it meets all criteria to be part of the current burst candidate
	# If it does not meet any criteria, continue to the next pulse
	for pulse in reversed(pulse_buffer[pulse_mask]):
		pulse_interval = pulse_next[PULSE_COLS.TS] - pulse[PULSE_COLS.TS]
		if pulse_interval < codes.intervals_min[interval_i] - burst_criteria['MAX_PULSE_SLOP'] or pulse_interval > codes.intervals_max[interval_i] + burst_criteria['MAX_PULSE_SLOP']:
			continue
		# Interpret the pulse interval as an integer code symbol
		symbol_float = (pulse_interval - codes.intervals_min[interval_i])/codes.interval_step
		symbol = np.round(symbol_float).astype(int)
		if symbol not in code_lookup:
			continue
		# Calculate the pulse interval slop by calculating the difference between the float symbol and the nearest integer symbol
		# Multiply this difference by the interval step to get the slop in seconds
		pulse_interval_slop = np.abs(symbol_float - symbol)*codes.interval_step
		if pulse_interval_slop > burst_criteria['MAX_PULSE_SLOP']:
			continue
		possible_burst_pulses = np.concatenate([[pulse], burst_pulses])
		if max(possible_burst_pulses[:,PULSE_COLS.SIG]) - min(possible_burst_pulses[:,PULSE_COLS.SIG]) > burst_criteria['MAX_SIG_RANGE']:
			continue
		if np.sum(possible_burst_pulses[:,PULSE_COLS.USED]) > burst_criteria['MAX_USED_PULSES']:
			continue
		if not check_freq_criteria(possible_burst_pulses, burst_criteria):
			continue
		# If there are fewer than 4 pulses, call this function recursively to look for additional valid pulses
		if len(possible_burst_pulses) < 4:
			result = find_pulses(pulse_buffer, possible_burst_pulses, code_lookup[symbol], burst_criteria, codes)
			if result is None:
				continue
			return result
		# Otherwise a valid burst has been found
		id = code_lookup[symbol]
		return possible_burst_pulses, id

def check_freq_criteria(burst_pulses, burst_criteria):
	# Check if difference between max and min freq is within tolerance
	freq_range = max(burst_pulses[:,PULSE_COLS.FREQ]) - min(burst_pulses[:,PULSE_COLS.FREQ])
	if freq_range <= burst_criteria['MAX_FREQ_RANGE']:
		return True
	# If not, and if freq outliers are allowed, then check again without the outliers
	pulse_mask = np.repeat(True, len(burst_pulses))
	for _ in range(burst_criteria['MAX_FREQ_OUTLIERS']):
		freq_diffs_mean = burst_pulses[:,PULSE_COLS.FREQ] - np.mean(burst_pulses[:,PULSE_COLS.FREQ])
		i_pulse = np.argmax(np.abs(freq_diffs_mean))
		# Only ignore the freq outlier if the sig is stronger that the weakest pulse in the burst
		if burst_pulses[i_pulse,PULSE_COLS.SIG] > np.min(burst_pulses[pulse_mask,PULSE_COLS.SIG]):
			pulse_mask[i_pulse] = False
	freq_range = max(burst_pulses[pulse_mask,PULSE_COLS.FREQ]) - min(burst_pulses[pulse_mask,PULSE_COLS.FREQ])
	if freq_range <= burst_criteria['MAX_FREQ_RANGE']:
		return True
	return False

def find_burst(pulse_buffer, burst_criteria, codes):
	if len(pulse_buffer) < 4:
		return None
	pulse_buffer = np.array(pulse_buffer)
	# Only consider bursts that end on the last pulse
	burst_pulses = np.expand_dims(pulse_buffer[-1],0)
	# For each pulse, find the preceding pulse that best fits a known code
	code_lookup = codes.code_lookup
	result = find_pulses(pulse_buffer, burst_pulses, code_lookup, burst_criteria, codes)
	if result is None:
		return None
	burst_pulses, id = result

	# Compile burst info
	ant = burst_pulses[0][PULSE_COLS.ANT]
	timestamp = burst_pulses[0][PULSE_COLS.TS]
	# Note that the sum of pulse_slops is calculated here for reporting purposes (for consistency with Tagfinder) even though it is the burstfinding algorithm uses the max pulse slop
	total_pulse_slop = np.sum(np.abs(np.diff(burst_pulses[:,PULSE_COLS.TS]) - codes.code_intervals[id])) / 1000 # Report value in seconds
	freq_mean = np.mean(burst_pulses[:,PULSE_COLS.FREQ])
	freq_sd = np.std(burst_pulses[:,PULSE_COLS.FREQ])
	freq_range = np.max(burst_pulses[:,PULSE_COLS.FREQ]) - np.min(burst_pulses[:,PULSE_COLS.FREQ])
	sig_mean = np.mean(burst_pulses[:,PULSE_COLS.SIG])
	sig_sd = np.std(burst_pulses[:,PULSE_COLS.SIG])
	sig_range = np.max(burst_pulses[:,PULSE_COLS.SIG]) - np.min(burst_pulses[:,PULSE_COLS.SIG])
	noise_mean = np.mean(burst_pulses[:,PULSE_COLS.NOISE])
	snr_min = np.min(burst_pulses[:,PULSE_COLS.SIG] - burst_pulses[:,PULSE_COLS.NOISE])
	used_pulses = np.sum(burst_pulses[:,PULSE_COLS.USED])
	num_pulses = len(pulse_buffer)
	pulses = {i:pulse for i, pulse in enumerate(burst_pulses)}

	burst = [ant, timestamp, id, freq_mean, freq_sd, freq_range, sig_mean, sig_sd, sig_range, noise_mean, total_pulse_slop, snr_min, used_pulses, num_pulses, burst_criteria['WARNING'], pulses]
	return burst

def update_used_pulses(pulse_buffer, burst):
	# Update pulse buffer to reflect which pulses have been used for this burst
	for i_burstpulse in burst[BURST_COLS.PULSES].keys():
		for i_pulse in range(len(pulse_buffer)):
			if pulse_buffer[i_pulse][PULSE_COLS.TS] == burst[BURST_COLS.PULSES][i_burstpulse][PULSE_COLS.TS]:
				pulse_buffer[i_pulse][PULSE_COLS.USED] += 1
				burst[BURST_COLS.PULSES][i_burstpulse][PULSE_COLS.USED] += 1
				break
	return pulse_buffer

# Remove duplicates from a list of detected bursts, leaving only the burst with the strongest mean signal strength
def aggregate_bursts(bursts):
	# Aggregate any duplicate detections
	if len(bursts) < 2:
		return bursts
	bursts = np.vstack(bursts)
	i_sorted = np.lexsort((bursts[:,BURST_COLS.ID],bursts[::-1,BURST_COLS.SIG_MEAN]))
	bursts = bursts[i_sorted]
	i_unique = np.unique(bursts[:,BURST_COLS.ID], return_index=True)[1]
	bursts = bursts[i_unique]
	return bursts

# Calculate the duration between the first and last pulse in the buffer
def get_buffer_dt(pulse_buffer):
	return pulse_buffer[-1][PULSE_COLS.TS] - pulse_buffer[0][PULSE_COLS.TS]

# Represent a list of bursts as a string (where each line is a burst), in preparation for writing to a burst file
def format_bursts(bursts):
	lines = ''
	for burst in bursts:
		sen, ts, id, freq_mean, freq_sd, freq_range, sig_mean, sig_sd, sig_range, noise_mean, interval_diff_max, snr_min, used_pulses, num_pulses, warning = burst[:-1]
		line = f'{sen:.0f},{ts:.4f},{id:.0f},{freq_mean:.3f},{freq_sd:.3f},{freq_range:.3f},{sig_mean:.3f},{sig_sd:.3f},{sig_range:.3f},{noise_mean:.3f},{interval_diff_max:.5f},{snr_min:.3f},{used_pulses:.0f},{num_pulses:.0f},{warning:.0f}\n'
		lines += line
	return lines

# Represent a list of bursts as a string (where each line is a pulse), in preparation for writing to a burst pulse file
def format_burstpulses(bursts):
	lines = ''
	for burst in bursts:
		id = burst[BURST_COLS.ID]
		for pulse in burst[BURST_COLS.PULSES].values():
			sen, ts, sig, freq, noise, used = pulse
			line = f'{sen:.0f},{ts:.4f},{sig:.3f},{freq:.3f},{noise:.3f},{id:.0f},{used:.0f}\n'
			lines += line
	return lines

# Parse a single line of text from a pulse file and return the pulse data (if it contains a pulse)
def parse_pulse_txt(pulse_txt):
	pulse = pulse_txt.rstrip().split(',')[:5]
	if len(pulse[0]) == 0: # This can happen when pulsefinder encounters an error
		return 'invalid' # Must be corrupted data
	if len(pulse[PULSE_COLS.ANT]) == 0 or pulse[PULSE_COLS.ANT][0] != 'p':
		return 'other' # Must be GPS record or something other than pulse data
	if len(pulse) < 5:
		return 'invalid' # Must be corrupted data
	pulse[PULSE_COLS.ANT] = pulse[PULSE_COLS.ANT].replace('p','')
	try:
		pulse = [float(v) for v in pulse]
		pulse[PULSE_COLS.ANT] = int(pulse[PULSE_COLS.ANT])
	except:
		logging.warning(f'  Invalid pulse data: {pulse_txt[:-1]}')
		return 'invalid'
	pulse[PULSE_COLS.FREQ] = abs(pulse[PULSE_COLS.FREQ])
	pulse.append(0) # Initialize counter for the number of times this pulse is used to identify a burst
	return pulse
	
def initialize_logging(args):
	if args.output != 'stdout':
		# If output is to a file, write log messages to the file's directory
		log_path = os.path.abspath(os.path.join(args.output, 'burstfinder.log'))
	else:
		# If output is to stdout, write log messages to the current working directory
		log_path = os.path.abspath('burstfinder.log')
	if args.log:
		# Override log path if it was specified as an argument
		log_path = os.path.abspath(args.log)
	log_handler = logging.FileHandler(os.path.abspath(log_path))
	log_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)7s - %(message)s'))
	logging.getLogger().addHandler(log_handler)
	# Only write log messages to stdout if bursts are not being written to stdout
	if args.output != 'stdout':
		# If output is to a file, write all log messages to stdout
		log_handler = logging.StreamHandler(sys.stdout)
		log_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)7s - %(message)s'))
		logging.getLogger().addHandler(log_handler)

	# Also write some log messages to stderr
	log_handler = logging.StreamHandler(sys.stderr)
	if args.output != 'stdout':
		# If output is to a file, write only error messages to stderr (requested by Denis for server operation)
		log_handler.setLevel(logging.ERROR)
	else:
		# IF output is to stdout, write all log messages to stderr (requested by Thorsten for sensorgnome operation)
		log_handler.setLevel(logging.INFO)
	log_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)7s - %(message)s'))
	logging.getLogger().addHandler(log_handler)

# Validate command line arguments
def validate_args(args):
	if not args.input == 'stdin' and not os.path.exists(args.input):
		raise ValueError('Input path does not exist')
	if not args.output == 'stdout' and not os.path.exists(args.output):
		os.makedirs(args.output, exist_ok=True)
	if args.log and not os.path.isdir(os.path.dirname(args.log)):
		raise ValueError('Log directory does not exist')
	
# Parse command line arguments
def parse_args():
	parser = argparse.ArgumentParser(description='Burstfinder')
	parser.add_argument('-i', '--input', type=str, default='stdin', help='Path to input files (either a pulse file or directory of pulse files), or "stdin" (default)')
	parser.add_argument('-o', '--output', type=str, default='stdout', help='Path to a directory for output files, or "stdout" (default)')
	parser.add_argument('-l', '--log', type=str, default='', help='Optional path for the log file (defaults to the output directory)')
	parser.add_argument('-c', '--codes', type=str, default='', help='Optional path to a YAML codeset definition (e.g. codes.yaml)')
	parser.add_argument('-s', '--settings', type=str, default='', help='Optional path to a YAML settings file (e.g. settings.yaml)')
	# Removed option to produce burstpulses based on 2025-03-06 agreement to only produce burst files
	parser.add_argument('-b', '--bursts', action='store_true', help='Optional flag to produce burst files')
	parser.add_argument('-p', '--pulses', action='store_true', help='Optional flag to produce filtered pulse files')
	parser.add_argument('-H', '--header', action='store_true', help='Optional flag to include a header in the output files')
	parser.add_argument('-T', '--text', action='store_true', help='Optional flag to write plain text files instead of gzipped text files')
	return parser.parse_args()

# Run the program
if __name__ == '__main__':
	try:
		args = parse_args()
		validate_args(args)
		initialize_logging(args)
		# Hardcoded arguments to produce bursts only and not burstpulses (see comment in parse_args)
		main(args.input, args.output, args.codes, args.settings, args.bursts, args.pulses, args.header, args.text)
	except KeyboardInterrupt:
		logging.error('Process interrupted by user')
		exit(2)
	except Exception:
		logging.error(f'Uknown error\n{traceback.format_exc()}')
		exit(1)