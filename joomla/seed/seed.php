<?php
/**
 * Siembra de contenido inicial para Joomla (Parcial II)
 *
 * Crea el articulo destacado "Prueba" con su imagen la primera vez que
 * se despliega el proyecto. Es idempotente: si el articulo ya existe,
 * no hace nada.
 *
 * Replica lo que hace Joomla al guardar un articulo desde el panel:
 *   - fila en #__content
 *   - nodo en el arbol de permisos #__assets (hijo de la categoria)
 *   - etapa del flujo de trabajo en #__workflow_associations
 *   - entrada en #__content_frontpage (articulo destacado)
 */

const RAIZ       = '/var/www/html';
const ALIAS      = 'prueba';
const IMG_ORIGEN = '/seed/images/culpa-de-abelardo.jpg';
const IMG_DIR    = RAIZ . '/images/parcial';
const IMG_URL    = 'images/parcial/culpa-de-abelardo.jpg';
const ESPERA_MAX = 600; // segundos

function msg(string $texto): void
{
    fwrite(STDERR, "[seed] $texto\n");
}

// 1. Esperar a que la instalacion automatica de Joomla termine
//    (el entrypoint oficial crea configuration.php y borra installation/)
$inicio = time();
while (!is_file(RAIZ . '/configuration.php') || is_dir(RAIZ . '/installation')) {
    if (time() - $inicio > ESPERA_MAX) {
        msg('Joomla no termino de instalarse a tiempo; se omite la siembra.');
        exit(0);
    }
    sleep(3);
}

// 2. Conexion a PostgreSQL con las mismas variables que usa Joomla
$prefijo = getenv('JOOMLA_DB_PREFIX') ?: 'jml_';
$dsn = sprintf('pgsql:host=%s;port=5432;dbname=%s', getenv('JOOMLA_DB_HOST'), getenv('JOOMLA_DB_NAME'));

try {
    $db = new PDO($dsn, getenv('JOOMLA_DB_USER'), getenv('JOOMLA_DB_PASSWORD'), [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);
} catch (PDOException $e) {
    msg('No se pudo conectar a PostgreSQL: ' . $e->getMessage());
    exit(0);
}

$t = fn(string $tabla): string => $prefijo . $tabla;

// 3. Idempotencia: si el articulo ya existe, no se vuelve a crear
$existe = $db->prepare("SELECT id FROM {$t('content')} WHERE alias = ?");
$existe->execute([ALIAS]);
if ($existe->fetchColumn()) {
    msg('El articulo "' . ALIAS . '" ya existe; nada que sembrar.');
    exit(0);
}

// 4. Copiar la imagen a la carpeta de medios de Joomla
if (!is_dir(IMG_DIR)) {
    mkdir(IMG_DIR, 0755, true);
}
copy(IMG_ORIGEN, IMG_DIR . '/culpa-de-abelardo.jpg');
chown(IMG_DIR, 'www-data');
chown(IMG_DIR . '/culpa-de-abelardo.jpg', 'www-data');

// 5. Insertar el articulo y sus registros asociados en una transaccion
$ahora   = gmdate('Y-m-d H:i:s');
$autor   = (int) $db->query("SELECT id FROM {$t('users')} ORDER BY id LIMIT 1")->fetchColumn();
$etapa   = (int) $db->query("SELECT id FROM {$t('workflow_stages')} ORDER BY id LIMIT 1")->fetchColumn();
$catId   = 2; // categoria "Uncategorised" de una instalacion limpia

$texto = '<p>Articulo de prueba creado automaticamente al desplegar el proyecto.</p>'
       . '<p><img src="' . IMG_URL . '" alt="Meme Abelardo" width="236" height="236" '
       . 'style="display: block; margin-left: auto; margin-right: auto;"></p>';

$images  = '{"image_intro":"","image_intro_alt":"","float_intro":"","image_intro_caption":"","image_fulltext":"","image_fulltext_alt":"","float_fulltext":"","image_fulltext_caption":""}';
$urls    = '{"urla":"","urlatext":"","targeta":"","urlb":"","urlbtext":"","targetb":"","urlc":"","urlctext":"","targetc":""}';
$attribs = '{"article_layout":"","show_title":"","link_titles":"","show_tags":"","show_intro":"","info_block_position":"","info_block_show_title":"","show_category":"","link_category":"","show_parent_category":"","link_parent_category":"","show_author":"","link_author":"","show_create_date":"","show_modify_date":"","show_publish_date":"","show_item_navigation":"","show_hits":"","show_noauth":"","urls_position":"","alternative_readmore":"","article_page_title":"","show_publishing_options":"","show_article_options":"","show_urls_images_backend":"","show_urls_images_frontend":""}';

try {
    $db->beginTransaction();

    // 5.1 Articulo (state 1 = publicado, featured 1 = destacado en la portada)
    $ins = $db->prepare(
        "INSERT INTO {$t('content')}
            (asset_id, title, alias, introtext, \"fulltext\", state, catid, created, created_by,
             created_by_alias, modified, modified_by, publish_up, images, urls, attribs,
             version, ordering, metakey, metadesc, access, hits, metadata, featured, language, note)
         VALUES (0, ?, ?, ?, '', 1, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, 1, 0, '', '', 1, 0,
                 '{\"robots\":\"\",\"author\":\"\",\"rights\":\"\"}', 1, '*', '')
         RETURNING id"
    );
    $ins->execute(['Prueba', ALIAS, $texto, $catId, $ahora, $autor, $ahora, $autor, $ahora, $images, $urls, $attribs]);
    $articuloId = (int) $ins->fetchColumn();

    // 5.2 Nodo de permisos (arbol de conjuntos anidados): hijo de la categoria
    $padre = $db->query(
        "SELECT id, rgt, level FROM {$t('assets')} WHERE name = 'com_content.category.$catId' FOR UPDATE"
    )->fetch(PDO::FETCH_ASSOC);
    $db->exec("UPDATE {$t('assets')} SET rgt = rgt + 2 WHERE rgt >= {$padre['rgt']}");
    $db->exec("UPDATE {$t('assets')} SET lft = lft + 2 WHERE lft > {$padre['rgt']}");
    $asset = $db->prepare(
        "INSERT INTO {$t('assets')} (parent_id, lft, rgt, level, name, title, rules)
         VALUES (?, ?, ?, ?, ?, ?, '{}') RETURNING id"
    );
    $asset->execute([
        $padre['id'], $padre['rgt'], $padre['rgt'] + 1, $padre['level'] + 1,
        "com_content.article.$articuloId", 'Prueba',
    ]);
    $assetId = (int) $asset->fetchColumn();
    $db->exec("UPDATE {$t('content')} SET asset_id = $assetId WHERE id = $articuloId");

    // 5.3 Etapa del flujo de trabajo (necesaria para que aparezca en el panel)
    $db->prepare("INSERT INTO {$t('workflow_associations')} (item_id, stage_id, extension) VALUES (?, ?, 'com_content.article')")
       ->execute([$articuloId, $etapa]);

    // 5.4 Articulo destacado: aparece en la portada (vista "featured")
    $db->prepare("INSERT INTO {$t('content_frontpage')} (content_id, ordering) VALUES (?, 1)")
       ->execute([$articuloId]);

    $db->commit();
    msg("Articulo \"Prueba\" (id $articuloId) creado con su imagen " . IMG_URL);
} catch (Throwable $e) {
    if ($db->inTransaction()) {
        $db->rollBack();
    }
    msg('Error al sembrar el articulo: ' . $e->getMessage());
}
