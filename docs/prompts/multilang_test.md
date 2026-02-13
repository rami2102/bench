there is multilang benchmark for the following agents: pi, codex, claude, gemini. 

refer to @scripts/languages/ for relevant scripts to run, run them in isolated container if possible

Please run total N=12 (default value which user can give as input to skill) sequential different tests split to batches of 3 (different) tests per each , split ai coding in parallel to:
pi, codex 
and after it:
claude, gemini (as pi and claude use same model).

give to gemini generous timeout (with claude) at least x5 time more.

at the end provide full summary of 2 tables:
1. test name, was it successful, number of lines generated for fix, number of lines generated for tests, is success by multilang benchmark

2. total summary per model

3. conclude which module performed best in this run

