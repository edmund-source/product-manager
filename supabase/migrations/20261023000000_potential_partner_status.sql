-- Business cards saved from the partner explorer start as 'potential_partner',
-- the stage before cold_inbound.
alter table companies drop constraint if exists companies_status_check;
alter table companies add constraint companies_status_check check (status in
  ('potential_partner','cold_inbound','intro','in_discussion','quoted','meeting_held',
   'accredited','active_supplier','declined','dormant','unknown'));
