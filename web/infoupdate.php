<?PHP 
include("definitions_i.php");
include("functions_i.php");

/* Need to clear PHP's internal cache */
clearstatcache();

/* Find most recent result in results dir */

$results_dir = $_GET["results_dir"];

$cmd = "ls -trA ".$results_dir." | tail -n 1";
$result = exec($cmd, $return_var);

$obs_info = $results_dir."/".$result."/obs.info";
$curr_archive = $results_dir."/".$result."/total_t_res.ar";

if (file_exists($obs_info)) {

  $header = getConfigFile($obs_info);

  echo "SOURCE:::".$header["SOURCE"].";;;";
  echo "RA:::".$header["RA"].";;;";
  echo "DEC:::".$header["DEC"].";;;";
  echo "CFREQ:::".$header["CFREQ"].";;;";
  echo "BANDWIDTH:::".$header["BANDWIDTH"].";;;";
  echo "NUM_PWC:::".$header["NUM_PWC"].";;;";
  echo "NPOL:::".$header["NPOL"].";;;";
  echo "NDIM:::".$header["NDIM"].";;;";
  echo "NBIT:::".$header["NBIT"].";;;";
  echo "PID:::".$header["PID"].";;;";
  echo "UTC_START:::".$result.";;;";

  $int_length = "0";
  if (file_exists($curr_archive)) {
    $int_length = getIntergrationLength($curr_archive);
  }  
  echo "INTEGRATED:::".$int_length." seconds;;;";

} else {

  echo "SOURCE:::None;;;";
  echo "RA:::None;;;";
  echo "DEC:::None;;;";
  echo "CFREQ:::None;;;";
  echo "BANDWIDTH:::None;;;";
  echo "NUM_PWC:::None;;;";
  echo "NPOL:::None;;;";
  echo "NDIM:::None;;;";
  echo "NBIT:::None;;;";
  echo "PID:::None;;;";
  echo "UTC_START:::None;;;";
  echo "INTEGRATED:::0;;;";

}