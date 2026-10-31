export function localDateParts(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(date);
  const map = Object.fromEntries(parts.map((p) => [p.type, p.value]));
  return { year: Number(map.year), month: Number(map.month), day: Number(map.day), date: `${map.year}-${map.month}-${map.day}` };
}
export function localDateToUTC(dateString, timeString, timeZone) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateString) || !/^([01]\d|2[0-3]):[0-5]\d$/.test(timeString)) throw new Error("Invalid local date/time");
  const [y,m,d] = dateString.split("-").map(Number);
  const [hh,mm] = timeString.split(":").map(Number);
  const naive = Date.UTC(y,m-1,d,hh,mm);
  const target = new Date(naive);
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hourCycle:"h23" }).formatToParts(target);
  const values = Object.fromEntries(parts.map(p=>[p.type,Number(p.value)]));
  const represented = Date.UTC(values.year,values.month-1,values.day,values.hour,values.minute);
  const corrected = new Date(naive - (represented-naive));
  // Iterative correction handles ordinary DST offsets without assuming a fixed UTC offset.
  const check = new Intl.DateTimeFormat("en-CA",{timeZone,year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hourCycle:"h23"}).formatToParts(corrected);
  const actual=Object.fromEntries(check.map(p=>[p.type,p.value]));
  if (`${actual.year}-${actual.month}-${actual.day}` !== dateString || `${actual.hour}:${actual.minute}` !== timeString) {
    const guess = new Date(naive);
    for (let i=0;i<4;i++) {
      const ps=new Intl.DateTimeFormat("en-CA",{timeZone,year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hourCycle:"h23"}).formatToParts(guess);
      const v=Object.fromEntries(ps.map(p=>[p.type,p.value]));
      const delta=naive-Date.UTC(Number(v.year),Number(v.month)-1,Number(v.day),Number(v.hour),Number(v.minute));
      guess.setTime(guess.getTime()+delta);
    }
    return guess;
  }
  return corrected;
}
