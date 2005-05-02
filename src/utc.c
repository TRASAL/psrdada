#include "utc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

time_t str2tm (struct tm* time, const char* str)
{
  char* temp = 0;         /* duplicate of input */
  int   trav = 0;         /* travelling index */
  int   endstr = 0;       /* length of string */
  char  infield = 0;      /* true when current character is a digit */
  int   field_count = 0;  /* incremented when character becomes digit */
  int   digits = 0;       /* count of digits in string */

  time->tm_year = 0;
  time->tm_mon = 0;
  time->tm_mday = 0;
  time->tm_hour = 0;
  time->tm_min = 0;
  time->tm_sec = 0;

  temp = strdup (str);

  /* count the number of fields and cut the string off after a year, day,
     hour, minute, and second can be parsed */
  while (temp[trav] != '\0') {
    if (isdigit(temp[trav])) {
      digits ++;
      if (!infield) {
	/* count only the transitions from non digits to a field of digits */
	field_count ++;
      }
      infield = 1;
    }
    else {
      infield = 0;
    }
    if (field_count == 6) {
      /* currently in the seconds field */
      temp[trav+2] = '\0';
      break;
    }
    else if (digits == 14) {
      /* enough digits for a date */
      temp[trav+1] = '\0';
      break;
    }
    trav ++;
  }

  endstr = strlen(temp);
  /* cut off any trailing characters that are not ASCII numbers */
  while ((endstr>=0) && !isdigit(temp[endstr])) endstr --;
  if (endstr < 0)
    return -1;
  temp [endstr+1] = '\0'; 


  /* parse UTC seconds */
  trav = endstr - 1;
  if ((trav < 0) || !isdigit(temp[trav]))
    trav++;
  sscanf (temp+trav, "%2d", &(time->tm_sec));

  /* cut out seconds and extra characters */
  endstr = trav-1;
  while ((endstr>=0) && !isdigit(temp[endstr])) endstr --;
  if (endstr < 0)
    return 0;
  temp [endstr+1] = '\0'; 

  /* parse UTC minutes */
  trav = endstr - 1;
  if ((trav < 0) || !isdigit(temp[trav]))
    trav++;
  sscanf (temp+trav, "%2d", &(time->tm_min));

  /* cut out minutes and extra characters */
  endstr = trav-1;
  while ((endstr>=0) && !isdigit(temp[endstr])) endstr --;
  if (endstr < 0)
    return 0;
  temp [endstr+1] = '\0'; 

  /* parse UTC hours */
  trav = endstr - 1;
  if ((trav < 0) || !isdigit(temp[trav]))
    trav++;
  sscanf (temp+trav, "%2d", &(time->tm_hour));

  /* cut out minutes and extra characters */
  endstr = trav-1;
  while ((endstr>=0) && !isdigit(temp[endstr])) endstr --;
  if (endstr < 0)
    return 0;
  temp [endstr+1] = '\0'; 

  /* parse UTC days in month */
  trav = endstr - 1;
  if ((trav < 0) || !isdigit(temp[trav]))
    trav++;
  sscanf (temp+trav, "%2d", &(time->tm_mday));

  /* cut out minutes and extra characters */
  endstr = trav-1;
  while ((endstr>=0) && !isdigit(temp[endstr])) endstr --;
  if (endstr < 0)
    return 0;
  temp [endstr+1] = '\0'; 

  /* parse UTC months */
  trav = endstr - 1;
  if ((trav < 0) || !isdigit(temp[trav]))
    trav++;
  sscanf (temp+trav, "%2d", &(time->tm_mon));
  /* month is stored 0->11 in struct tm */
  time->tm_mon --;

  /* cut out minutes and extra characters */
  endstr = trav-1;
  while ((endstr>=0) && !isdigit(temp[endstr])) endstr --;
  if (endstr < 0)
    return 0;
  temp [endstr+1] = '\0'; 

  /* parse UTC year */
  trav = endstr;
  while ((trav >= 0) && (endstr-trav < 4) && isdigit(temp[trav]))
    trav--;
  sscanf (temp+trav+1, "%4d", &(time->tm_year));

  free (temp);

  time->tm_wday = 0;
  time->tm_yday = 0;
  time->tm_isdst = -1;

  /* this may cause a Y3.8K bug */
  if (time->tm_year > 1900)
    time->tm_year -= 1900;

  /* Y2K bug assumption */
  if (time->tm_year < 30)
     time->tm_year += 100;

  return mktime (time);
  
} 

