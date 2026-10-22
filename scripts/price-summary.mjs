// Prints a price summary per category (solar equipment first): every priced
// line, latest per seller, in PHP excluding VAT with per-W / per-kWh / per-kW
// where known. Unmatched lines use the category the importer noted.
//
//   DATABASE_URL=... node scripts/price-summary.mjs [category ...]
import pg from 'pg';

const only = process.argv.slice(2);
const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();

const { rows } = await client.query(
  `select coalesce(lp.category_key, substring(ep.notes from 'category: ([a-z_]+)'), 'other') as category,
          coalesce(pc.solar, true) and coalesce(pc.family, 'equipment') = 'equipment' as solar,
          coalesce(lp.product_name, lp.raw_product_name) as product,
          lp.seller, lp.source_type as source, lp.quoted_on::text as quoted_on,
          lp.price_original as price, lp.currency, lp.unit, lp.min_qty, lp.vat_included,
          lp.unit_php_ex_vat as php_ex_vat, lp.php_per_w, lp.php_per_kwh, lp.php_per_kw
   from pricing.latest_prices lp
   join pricing.equipment_prices ep on ep.id = lp.id
   left join public.product_categories pc
     on pc.key = coalesce(lp.category_key, substring(ep.notes from 'category: ([a-z_]+)'))
   order by solar desc, coalesce(pc.key, 'zz'), product, lp.unit_php_ex_vat`,
);
const { rows: [gaps] } = await client.query(
  `select count(*) filter (where price is null) as no_price,
          count(*) filter (where product_id is null) as unmatched
   from pricing.equipment_prices`,
);
await client.end();

const byCategory = Map.groupBy(rows.filter((r) => !only.length || only.includes(r.category)),
  (r) => r.category);
for (const [category, lines] of byCategory) {
  const php = lines.filter((r) => r.unit === 'piece').map((r) => Number(r.php_ex_vat))
    .filter((n) => n > 0);
  console.log(`\n${category} — ${lines.length} prices` +
    (php.length ? `, ₱${Math.min(...php).toLocaleString()}–₱${Math.max(...php).toLocaleString()} per piece ex VAT` : ''));
  console.table(lines.map(({ category, solar, ...r }) => r));
}
console.log(`\nQuoted without a price (e.g. in an attachment): ${gaps.no_price}; ` +
  `not yet matched to a product: ${gaps.unmatched}`);
