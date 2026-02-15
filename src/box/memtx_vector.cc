#include "memtx_vector.h"

#include <small/small.h>
#include <small/mempool.h>

#include "index.h"
#include "errinj.h"
#include "fiber.h"
#include "trivia/util.h"

#include "tuple.h"
#include "txn.h"
#include "memtx_tx.h"
#include "space.h"
#include "schema.h"
#include "memtx_engine.h"
#include "../../third_party/USearch/c/usearch.h"

struct memtx_vector_index {
	struct index base;
	unsigned dimension;
	usearch_index_t idx;
};

struct index_vector_iterator {
	struct iterator base;
	uint64_t key;
	struct key_def *pk_def;
	/** Memory pool the iterator was allocated from. */
	struct mempool *pool;
};

static inline int
mp_decode_num(const char **data, uint32_t fieldno, double *ret)
{
	if (mp_read_double(data, ret) != 0) {
		diag_set(ClientError, ER_FIELD_TYPE,
			 int2str(fieldno + TUPLE_INDEX_BASE),
			 field_type_strs[FIELD_TYPE_NUMBER],
			 mp_type_strs[mp_typeof(**data)]);
		return -1;
	}
	return 0;
}

static inline int
mp_decode_vector(double **vector, unsigned dimension,
	         const char *mp, unsigned count, const char *what)
{
	(void)what;
	double c = 0;
    if (count == dimension) {
        for (unsigned i = 0; i < dimension; i++) {
            if (mp_decode_num(&mp, i, &c) < 0)
                return -1;
            (*vector)[i] = c;
        }
    } else {
		diag_set(ClientError, ER_RTREE_RECT,
			 what, dimension, dimension);
		return -1;
    }
	return 0;
}

static inline int
mp_decode_vector_from_key(double **vector, unsigned dimensions,
			  const char *mp, uint32_t part_count)
{
	if (part_count == 1)
		part_count = mp_decode_array(&mp);
	return mp_decode_vector(vector, dimensions, mp, part_count, "Key");
}

static inline int
extract_vector(double **vector, struct tuple *tuple,
	       struct index_def *index_def)
{
	assert(index_def->key_def->part_count == 1);
	assert(!index_def->key_def->is_multikey);
	const char *elems = tuple_field_by_part(tuple,
				index_def->key_def->parts, MULTIKEY_NONE);
	unsigned dimension = index_def->opts.dimension;
	uint32_t count = mp_decode_array(&elems);
	return mp_decode_vector(vector, dimension, elems, count, "Field");
}

static int
memtx_vector_index_get_internal(struct index *base, const char *key,
			       uint32_t part_count, struct tuple **result)
{
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;

	double *vector;
	if (mp_decode_vector_from_key(&vector, index->dimension, key, part_count))
		unreachable();

	*result = NULL;

	/*if (!rtree_search(&index->idx, &rect, SOP_OVERLAPS, &iterator)) {
		rtree_iterator_destroy(&iterator);
		return 0;
	}
	do {
		struct tuple *tuple = (struct tuple *)
			rtree_iterator_next(&iterator);
		if (tuple == NULL)
			break;
		struct txn *txn = in_txn();
		struct space *space = space_by_id(base->def->space_id);
		*result = memtx_tx_tuple_clarify(txn, space, tuple, base, 0);
	} while (*result == NULL);*/
	return 0;
}

static int
index_vector_iterator_next(struct iterator *i, struct tuple **ret)
{
	struct index_vector_iterator *itr = (struct index_vector_iterator *)i;
	struct space *space;
	struct index *index;
	index_weak_ref_get_checked(&i->index_ref, &space, &index);

	*ret = (struct tuple *) itr->key;
	if (*ret == NULL)
		return 0;

	itr->key = 0;
	struct txn *txn = in_txn();
	*ret = memtx_tx_tuple_clarify(txn, space, *ret, index, 0);

	return 0;
}

static void
index_vector_iterator_free(struct iterator *i)
{
	struct index_vector_iterator *itr = (struct index_vector_iterator *)i;
	mempool_free(itr->pool, itr);
}

#define M_NEIGHBOURS 32

/** Implementation of create_iterator for memtx vector index. */
static struct iterator *
memtx_vector_index_create_iterator(struct index *base, enum iterator_type type,
				  const char *key, uint32_t part_count,
				  const char *pos)
{
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;
	struct memtx_engine *memtx = (struct memtx_engine *)base->engine;

	if (pos != NULL) {
		diag_set(UnsupportedIndexFeature, base->def, "pagination");
		return NULL;
	}

	double *vector = (double*) xcalloc(index->dimension, sizeof(double));
	if (part_count == 0) {
		assert(type == ITER_ALL);
	} else if (mp_decode_vector_from_key(&vector, index->dimension,
					     key, part_count)) {
		return NULL;
	}

	struct index_vector_iterator *it = (struct index_vector_iterator *)
		mempool_alloc(&memtx->iterator_pool);
	if (it == NULL) {
		diag_set(OutOfMemory, sizeof(struct index_vector_iterator),
			 "memtx_vector_index", "iterator");
		return NULL;
	}

	iterator_create(&it->base, base);
	it->pool = &memtx->iterator_pool;
	it->base.next_internal = index_vector_iterator_next;
	it->base.next = memtx_iterator_next;
	it->base.position = generic_iterator_position;
	it->base.free =index_vector_iterator_free;

	usearch_error_t error = NULL;
	switch (type) {
	case ITER_EQ:
	{
		usearch_key_t found_keys[M_NEIGHBOURS];
		usearch_distance_t found_distances[M_NEIGHBOURS];

		size_t matches = usearch_search(
			index->idx, vector, usearch_scalar_f64_k, M_NEIGHBOURS,
			found_keys, found_distances, &error);

		if (matches > 0)
			it->key = found_keys[0];

		break;
	}
	default:
		unreachable();
	}

	return (struct iterator *)it;
}

static int
memtx_vector_index_replace(struct index *base, struct tuple *old_tuple,
			  struct tuple *new_tuple, enum dup_replace_mode mode,
			  struct tuple **result, struct tuple **successor)
{
	(void)mode;
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;

	/* TODO: support ordering by distance? */
	*successor = NULL;

	double *vector = (double*) xcalloc(index->dimension, sizeof(double));
	usearch_error_t error = NULL;
	struct key_def *pk_def = base->def->pk_def;
	uint32_t pk_size;
	if (new_tuple) {
		/*const char *pk_key_mp = tuple_extract_key(new_tuple, pk_def,
							MULTIKEY_NONE, &pk_size);
		(void)pk_key_mp;
		double pk_key = 0;
		mp_decode_array(&pk_key_mp);
		mp_decode_num(&pk_key_mp, 0, &pk_key);
		*/
		uint64_t key = *((uint64_t*) &new_tuple);
		if (extract_vector(&vector, new_tuple, base->def) != 0)
			return -1;
		usearch_add(index->idx, key, vector, usearch_scalar_f64_k, &error);
	}
	if (old_tuple) {
		const char *pk_key_ = tuple_extract_key(old_tuple, pk_def,
							MULTIKEY_NONE, &pk_size);
		uint64_t pk_key = *((uint64_t*) &pk_key_);
		(void)pk_key;

		if (extract_vector(&vector, old_tuple, base->def) != 0)
			return -1;
		if (false) /* TODO */
			old_tuple = NULL;
	}
	*result = old_tuple;
	return 0;
}

static void
memtx_vector_index_destroy(struct index *base)
{
	usearch_error_t error = NULL;
	struct memtx_vector_index *index = (struct memtx_vector_index *)base;
	usearch_free(index->idx, &error);
	free(index);
}

static const struct index_vtab memtx_vector_index_vtab = {
	/* .destroy = */ memtx_vector_index_destroy,
	/* .commit_create = */ generic_index_commit_create,
	/* .abort_create = */ generic_index_abort_create,
	/* .commit_modify = */ generic_index_commit_modify,
	/* .commit_drop = */ generic_index_commit_drop,
	/* .update_def = */ generic_index_update_def,
	/* .depends_on_pk = */ generic_index_depends_on_pk,
	/* .def_change_requires_rebuild = */
		generic_index_def_change_requires_rebuild,
	/* .size = */ generic_index_size,
	/* .bsize = */ generic_index_bsize,
	/* .quantile = */ generic_index_quantile,
	/* .min = */ generic_index_min,
	/* .max = */ generic_index_max,
	/* .random = */ generic_index_random,
	/* .count = */ generic_index_count,
	/* .get_internal = */ memtx_vector_index_get_internal,
	/* .get = */ memtx_index_get,
	/* .replace = */ memtx_vector_index_replace,
	/* .create_iterator = */ memtx_vector_index_create_iterator,
	/* .create_iterator_with_offset = */
	generic_index_create_iterator_with_offset,
	/* .create_arrow_stream = */ generic_index_create_arrow_stream,
	/* .create_read_view = */ generic_index_create_read_view,
	/* .stat = */ generic_index_stat,
	/* .compact = */ generic_index_compact,
	/* .reset_stat = */ generic_index_reset_stat,
	/* .begin_build = */ generic_index_begin_build,
	/* .reserve = */ generic_index_reserve,
	/* .build_next = */ generic_index_build_next,
	/* .end_build = */ generic_index_end_build,
};

struct index *
memtx_vector_index_new(struct memtx_engine *memtx, struct index_def *def)
{
	assert(def->iid > 0);
	assert(def->key_def->part_count == 1);
	assert(def->key_def->parts[0].type == FIELD_TYPE_ARRAY);
	assert(def->opts.is_unique == false);

	// TODO: check dimension count.
	assert(def->opts.dimension >= 1 && def->opts.dimension < 1000);

	// TODO: try different distance types.

	struct memtx_vector_index *index =
		(struct memtx_vector_index *)xcalloc(1, sizeof(*index));
	index_create(&index->base, (struct engine *)memtx,
		     &memtx_vector_index_vtab, def);

	usearch_init_options_t opts = {
		.metric_kind = usearch_metric_cos_k,
		.quantization = usearch_scalar_f64_k,
		.dimensions = (size_t) def->opts.dimension,
		.expansion_add = 0, // for defaults
		.expansion_search = 0 // for defaults
	};

	usearch_error_t error = NULL;
	index->idx = usearch_init(&opts, &error);
	size_t vectors_count = 1000;
	usearch_reserve(index->idx, vectors_count, &error);

	index->dimension = def->opts.dimension;
	return &index->base;
}
