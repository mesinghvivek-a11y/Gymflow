import test from 'node:test';
import assert from 'node:assert/strict';
import {addCalendarMonths,isMembershipActive,renewalStart,deriveMembershipStatus} from '../src/domain/membership.js';
import {rupeesToPaise,formatINR} from '../src/domain/money.js';
import {isValidMemberNumber,nextCandidate} from '../src/domain/member-id.js';
import {normalizeIndianPhone} from '../src/domain/phone.js';
import {localDateParts,localDateToUTC} from '../src/domain/timezone.js';

test('calendar month arithmetic clamps month-end and handles leap year',()=>{
 assert.equal(addCalendarMonths(new Date('2026-01-31T10:00:00Z'),1).toISOString(),'2026-02-28T10:00:00.000Z');
 assert.equal(addCalendarMonths(new Date('2024-01-31T10:00:00Z'),1).toISOString(),'2024-02-29T10:00:00.000Z');
});
test('membership end is exclusive',()=>{const a=new Date('2026-01-01Z'),b=new Date('2026-02-01Z');assert.equal(isMembershipActive(a,b,new Date('2026-01-31T23:59:59Z')),true);assert.equal(isMembershipActive(a,b,b),false);});
test('advance renewal preserves unused time; expired renewal begins selected date',()=>{const now=new Date('2026-01-10Z'),end=new Date('2026-01-20Z');assert.equal(renewalStart(end,now).toISOString(),end.toISOString());assert.equal(renewalStart(new Date('2026-01-01Z'),now).toISOString(),now.toISOString());});
test('status priority and due windows are deterministic',()=>{const now=new Date('2026-01-10T00:00:00Z'),base={startsAt:new Date('2026-01-01Z'),endsAt:new Date('2026-01-20Z'),now};assert.equal(deriveMembershipStatus({...base,paused:true}),'paused');assert.equal(deriveMembershipStatus({...base,cancelled:true}),'cancelled');assert.equal(deriveMembershipStatus({...base,endsAt:now}),'expired');});
test('INR values convert to integer paise and reject non-finite/negative values',()=>{assert.equal(rupeesToPaise('499.99'),49999);assert.throws(()=>rupeesToPaise(-1));assert.throws(()=>rupeesToPaise('NaN'));assert.match(formatINR(125050),/1,250\.50/);});
test('member IDs are five digits and candidate allocation is gym-local',()=>{assert.equal(isValidMemberNumber('12345'),true);assert.equal(isValidMemberNumber('1234'),false);assert.equal(nextCandidate(new Set([10000,10001]),10000),10002);});
test('Indian mobile number input normalizes to E.164',()=>{assert.equal(normalizeIndianPhone('98765 43210'),'+919876543210');assert.equal(normalizeIndianPhone('09123456789'),'+919123456789');assert.equal(normalizeIndianPhone('+447911123456'),'+447911123456');assert.equal(normalizeIndianPhone('12345'),null);});
test('gym-local date helper handles India and New York DST',()=>{assert.equal(localDateParts(new Date('2026-01-01T00:00:00Z'),'Asia/Kolkata').date,'2026-01-01');const d=localDateToUTC('2026-07-15','09:30','America/New_York');assert.equal(new Intl.DateTimeFormat('en-US',{timeZone:'America/New_York',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).format(d),'09:30');});
